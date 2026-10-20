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

public struct EmbeddingIndexStatus: Sendable {
    public let message: String
    public let fraction: Double?
    public let canRetry: Bool

    public static let disabled = EmbeddingIndexStatus(
        message: "Включите модель, чтобы подготовить поиск по смыслу.", fraction: nil, canRetry: false)
}

/// Owns a separate SQLite connection. No database transaction spans model inference.
/// Pending work lives in SQLite; cancelling a task never marks its unfinished job complete.
public actor EmbeddingIndexer {
    private let databaseURL: URL
    private let access: LocalModelReadAccess
    private let runtime: EmbeddingRuntime
    private let onProgress: @Sendable (EmbeddingIndexStatus) -> Void
    private let onIndexed: @Sendable () -> Void
    private let documentProvider: (@Sendable (String) async throws -> EmbeddingOutput)?
    private let testIdentity: EmbeddingIndexIdentity?
    private let shutdownState = IndexShutdownState()
    private var store: HistoryStore?
    private var enabled = false
    private var blocked = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var lastProgressAt = Date.distantPast

    public init(databaseURL: URL, modelRootURL: URL, bundleURL: URL = Bundle.main.bundleURL,
                onProgress: @escaping @Sendable (EmbeddingIndexStatus) -> Void,
                onIndexed: @escaping @Sendable () -> Void) {
        self.databaseURL = databaseURL
        access = LocalModelReadAccess(rootURL: modelRootURL)
        runtime = EmbeddingRuntime(modelRootURL: modelRootURL, bundleURL: bundleURL)
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
        testIdentity = identity; self.documentProvider = documentProvider
        self.onProgress = onProgress; self.onIndexed = onIndexed
    }

    public func setEnabled(_ value: Bool) {
        guard !shutdownState.isStopped else { return }
        guard value != enabled else { return }
        enabled = value; generation += 1
        task?.cancel(); task = nil
        blocked = false
        if value { schedule() }
        else {
            runtime.unload()
            onProgress(.disabled)
        }
    }

    public func schedule() {
        guard enabled, !blocked, task == nil, !shutdownState.isStopped else { return }
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
        runtime.shutdown()
    }

    private func drain(generation token: Int) async {
        defer { if token == generation { task = nil } }
        do {
            guard !shutdownState.isStopped else { return }
            let identity: EmbeddingIndexIdentity
            if let testIdentity { identity = testIdentity }
            else {
                identity = EmbeddingIndexIdentity(fingerprint: try access.enabledEmbedding().modelKey,
                                                  dimensions: EmbeddingConfiguration.dimensions)
            }
            if store == nil { store = try HistoryStore(url: databaseURL) }
            guard let store else { return }
            if try store.embeddingIndexIdentity() != identity {
                onProgress(EmbeddingIndexStatus(message: "Подготовка индекса…", fraction: nil, canRetry: false))
                try store.configureEmbeddingIndex(identity)
            }
            // Failed work can be retried on re-enable/relaunch, but never spins within one drain.
            try store.retryFailedEmbeddings()
            while enabled, token == generation, !shutdownState.isStopped {
                try Task.checkCancellation()
                try publish(store)
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
        if progress.pending > 0 {
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
            canRetry: progress.failed > 0))
    }

    private func report(_ error: Error) {
        blocked = true
        runtime.unload()
        onProgress(EmbeddingIndexStatus(message: "Индексация приостановлена: \(error.localizedDescription)",
                                        fraction: nil, canRetry: true))
    }
}
