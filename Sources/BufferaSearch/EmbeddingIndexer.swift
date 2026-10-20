import Foundation
import BufferaCore
import BufferaModels

/// Termination can run outside the actor while its inference task is suspended.
/// This flag prevents a worker's shutdown error from turning pending work into a failure.
private final class IndexShutdownState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

public enum EmbeddingIndexPauseReason: Sendable, Equatable {
    case battery, lowPowerMode, thermalPressure, foregroundChat, powerSourceUnknown

    public var message: String {
        switch self {
        case .battery: return "Подготовка на паузе: Mac работает от аккумулятора."
        case .lowPowerMode: return "Подготовка на паузе: включён режим энергосбережения."
        case .thermalPressure: return "Подготовка на паузе: Mac нужно остыть."
        case .foregroundChat: return "Подготовка на паузе, пока Buffera отвечает на вопрос."
        case .powerSourceUnknown: return "Подготовка на паузе: не удалось определить источник питания."
        }
    }
}

public struct EmbeddingIndexStatus: Sendable {
    public let message: String
    public let fraction: Double?
    public let canRetry: Bool
    public let pauseReason: EmbeddingIndexPauseReason?
    public var canContinueNow: Bool { pauseReason == .battery }

    public init(message: String, fraction: Double?, canRetry: Bool,
                pauseReason: EmbeddingIndexPauseReason? = nil) {
        self.message = message; self.fraction = fraction; self.canRetry = canRetry
        self.pauseReason = pauseReason
    }

    public static let disabled = EmbeddingIndexStatus(
        message: "Включите «Поиск по смыслу» в настройках, чтобы подготовить историю.", fraction: nil, canRetry: false)
}

/// Owns a separate SQLite connection. No database transaction spans model inference.
/// Pending work lives in SQLite; cancelling a task never marks its unfinished job complete.
public actor EmbeddingIndexer {
    private let databaseURL: URL
    private let access: LocalModelReadAccess
    private let runtime: EmbeddingRuntime
    private let ownsRuntime: Bool
    private let onProgress: @Sendable (EmbeddingIndexStatus) -> Void
    private let onIndexed: @Sendable () -> Void
    private let documentProvider: (@Sendable (String) async throws -> EmbeddingOutput)?
    private let testIdentity: EmbeddingIndexIdentity?
    private let shutdownState = IndexShutdownState()
    private var store: HistoryStore?
    private var enabled = false
    private var blocked = false
    private var pauseReason: EmbeddingIndexPauseReason?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var lastProgressAt = Date.distantPast

    public init(databaseURL: URL, modelRootURL: URL, bundleURL: URL = Bundle.main.bundleURL,
                embeddingRuntime: EmbeddingRuntime? = nil,
                onProgress: @escaping @Sendable (EmbeddingIndexStatus) -> Void,
                onIndexed: @escaping @Sendable () -> Void) {
        self.databaseURL = databaseURL
        access = LocalModelReadAccess(rootURL: modelRootURL)
        runtime = embeddingRuntime ?? EmbeddingRuntime(modelRootURL: modelRootURL, bundleURL: bundleURL)
        ownsRuntime = embeddingRuntime == nil
        self.onProgress = onProgress; self.onIndexed = onIndexed
        documentProvider = nil; testIdentity = nil
    }

    /// A deterministic inference boundary for lifecycle tests on temporary history.
    public init(databaseURL: URL, identity: EmbeddingIndexIdentity,
                documentProvider: @escaping @Sendable (String) async throws -> EmbeddingOutput,
                onProgress: @escaping @Sendable (EmbeddingIndexStatus) -> Void,
                onIndexed: @escaping @Sendable () -> Void) {
        self.databaseURL = databaseURL
        access = LocalModelReadAccess(rootURL: databaseURL.deletingLastPathComponent())
        runtime = EmbeddingRuntime(modelRootURL: databaseURL.deletingLastPathComponent())
        ownsRuntime = true
        testIdentity = identity; self.documentProvider = documentProvider
        self.onProgress = onProgress; self.onIndexed = onIndexed
    }

    public func setEnabled(_ value: Bool) {
        guard !shutdownState.isStopped else { return }
        // A rapid OFF → ON can make the application discard its stale OFF delivery.
        // Reasserting ON must replace any interrupted drain, even when this actor missed OFF.
        guard value || enabled else { return }
        enabled = value; generation += 1
        task?.cancel(); task = nil
        blocked = false
        if value { schedule() }
        else {
            if ownsRuntime { runtime.unload() }
            onProgress(.disabled)
        }
    }

    /// A pause finishes the current document, then stops taking work from SQLite.
    /// It does not cancel another consumer's query or change durable pending jobs.
    public func setPaused(reason: EmbeddingIndexPauseReason?) {
        guard !shutdownState.isStopped, pauseReason != reason else { return }
        pauseReason = reason
        guard enabled else { return }
        if reason != nil || blocked { publishPauseStatus() }
        else { schedule() }
    }

    public func schedule() {
        guard enabled, !blocked, task == nil, !shutdownState.isStopped else { return }
        guard pauseReason == nil else { publishPauseStatus(); return }
        let token = generation
        task = Task { await drain(generation: token) }
    }

    public func retry() {
        guard enabled, task == nil, !shutdownState.isStopped else { return }
        blocked = false
        do { try store?.retryFailedEmbeddings(); schedule() }
        catch { report(error) }
    }

    /// Synchronous process teardown is needed while NSApplication is terminating.
    public nonisolated func shutdown() {
        shutdownState.stop()
        if ownsRuntime { runtime.shutdown() }
    }

    private func prepareStore() throws -> (HistoryStore, EmbeddingIndexIdentity) {
        let identity: EmbeddingIndexIdentity
        if let testIdentity { identity = testIdentity }
        else {
            identity = EmbeddingIndexIdentity(fingerprint: try access.enabledEmbedding().modelKey,
                                              dimensions: EmbeddingConfiguration.dimensions)
        }
        if store == nil { store = try HistoryStore(url: databaseURL) }
        guard let store else { throw HistoryError.database("Не удалось открыть историю для поиска.") }
        if try store.embeddingIndexIdentity() != identity {
            try store.configureEmbeddingIndex(identity)
        }
        return (store, identity)
    }

    private func publishPauseStatus() {
        do {
            let (store, _) = try prepareStore()
            try publish(store, force: true)
        } catch { report(error) }
    }

    private func drain(generation token: Int) async {
        defer { if token == generation { task = nil } }
        do {
            guard !shutdownState.isStopped else { return }
            let (store, identity) = try prepareStore()
            // Failed work can be retried on re-enable/relaunch, but never spins within one drain.
            try store.retryFailedEmbeddings()
            while enabled, token == generation, !shutdownState.isStopped {
                try Task.checkCancellation()
                try publish(store)
                guard pauseReason == nil else { break }
                guard let job = try store.nextPendingEmbedding() else { break }
                do {
                    let output: EmbeddingOutput
                    if let documentProvider { output = try await documentProvider(job.text) }
                    else {
                        guard let first = try await runtime.embed([job.text], kind: .document).first else {
                            throw EmbeddingRuntimeError.invalidResponse
                        }
                        output = first
                    }
                    try Task.checkCancellation()
                    guard enabled, token == generation, !shutdownState.isStopped else { return }
                    if testIdentity == nil,
                       try access.enabledEmbedding().modelKey != identity.fingerprint {
                        throw EmbeddingRuntimeError.unavailable
                    }
                    if try store.completeEmbedding(job, vectors: output.vectors, isTruncated: output.truncated) {
                        onIndexed()
                    }
                } catch is CancellationError { return }
                catch EmbeddingRuntimeError.stopped { return }
                catch {
                    guard enabled, token == generation, !shutdownState.isStopped else { return }
                    _ = try store.failEmbedding(job)
                    throw error
                }
                // Give captures and user requests a chance between documents.
                await Task.yield()
            }
            if !shutdownState.isStopped { try publish(store, force: true) }
        } catch is CancellationError {
            return
        } catch {
            guard enabled, token == generation, !shutdownState.isStopped else { return }
            report(error)
        }
    }

    private func publish(_ store: HistoryStore, force: Bool = false) throws {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgressAt) >= 0.5 else { return }
        lastProgressAt = now
        let progress = try store.embeddingProgress()
        let message: String
        let effectivePause = progress.pending > 0 ? pauseReason : nil
        if let effectivePause {
            message = "\(effectivePause.message) Готово: \(progress.complete) из \(progress.total), осталось: \(progress.pending)."
        } else if progress.pending > 0 {
            message = "Подготовлено \(progress.complete) из \(progress.total) записей"
        } else if progress.failed > 0 {
            message = "Готово: \(progress.complete). Не удалось обработать: \(progress.failed)"
        } else if progress.total == 0 {
            message = "Пока нет текста для поиска по смыслу."
        } else {
            message = "Поиск по смыслу готов: \(progress.complete) записей"
        }
        let suffix = progress.truncated > 0
            ? ". Длинных записей обработано частично: \(progress.truncated)" : ""
        onProgress(EmbeddingIndexStatus(message: message + suffix,
            fraction: progress.pending > 0 && progress.total > 0
                ? Double(progress.complete) / Double(progress.total) : nil,
            canRetry: progress.failed > 0, pauseReason: effectivePause))
    }

    private func report(_ error: Error) {
        blocked = true
        if ownsRuntime { runtime.unload() }
        onProgress(EmbeddingIndexStatus(message: "Индексация приостановлена: \(error.localizedDescription)",
                                        fraction: nil, canRetry: true))
    }
}
