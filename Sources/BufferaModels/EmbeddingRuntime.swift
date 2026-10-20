import Darwin
import Foundation

public enum EmbeddingInputKind: String, Codable, Sendable {
    case document, query
}

public struct EmbeddingOutput: Codable, Sendable {
    public let vectors: [[Float]]
    public let truncated: Bool

    public init(vectors: [[Float]], truncated: Bool) {
        self.vectors = vectors
        self.truncated = truncated
    }
}

/// A reusable, local process owns all model and GPU memory. The serial queue only handles
/// state transitions; hashing and pipe writes never prevent cancellation or shutdown.
public final class EmbeddingRuntime: @unchecked Sendable {
    private final class Request {
        let id: UUID
        let texts: [String]
        let kind: EmbeddingInputKind
        let cancellation: ModelVerification
        private var continuation: CheckedContinuation<[EmbeddingOutput], Error>?
        var timeout: DispatchWorkItem?

        init(id: UUID, texts: [String], kind: EmbeddingInputKind,
             cancellation: ModelVerification,
             continuation: CheckedContinuation<[EmbeddingOutput], Error>) {
            self.id = id
            self.texts = texts
            self.kind = kind
            self.cancellation = cancellation
            self.continuation = continuation
        }

        var isCancelled: Bool {
            do { try cancellation.checkCancellation(); return false }
            catch { return true }
        }

        // A cancelled query still owns its protocol response, but no longer owns a caller.
        func finish(_ result: Result<[EmbeddingOutput], Error>) {
            let callback = continuation
            continuation = nil
            callback?.resume(with: result)
        }
    }

    private final class Run {
        let id = UUID()
        let model: InstalledEmbeddingModel
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let verification = ModelVerification()
        var reader: DispatchSourceRead?
        var ready = false
        var received = Data()

        init(model: InstalledEmbeddingModel) { self.model = model }
    }

    private struct WireRequest: Encodable {
        let id: String
        let kind: EmbeddingInputKind
        let texts: [String]
    }

    private struct WireResponse: Decodable {
        let id: String
        let outputs: [EmbeddingOutput]?
        let error: String?
    }

    private static let maximumFrame = 4 * 1024 * 1024
    private let queue = DispatchQueue(label: "app.buffera.embeddings", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let access: LocalModelReadAccess
    private let executable: URL
    private let idleTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private var pending: [Request] = []
    private var active: Request?
    private var run: Run?
    private var idle: DispatchWorkItem?
    private var availabilityTimer: DispatchSourceTimer?
    private var stopped = false

    public init(modelRootURL: URL, bundleURL: URL = Bundle.main.bundleURL,
                executableURL: URL? = nil, idleTimeout: TimeInterval = 60,
                requestTimeout: TimeInterval = 180,
                descriptor: LocalModelDescriptor = LocalModelCatalog.models.first { $0.role == .embedding }!) {
        access = LocalModelReadAccess(rootURL: modelRootURL, descriptor: descriptor)
        executable = executableURL ?? bundleURL.appendingPathComponent("Contents/MacOS/BufferaEmbeddingWorker")
        self.idleTimeout = max(0.05, idleTimeout)
        self.requestTimeout = max(0.05, requestTimeout)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { shutdown() }

    public func embed(_ texts: [String], kind: EmbeddingInputKind) async throws -> [EmbeddingOutput] {
        try Task.checkCancellation()
        guard !texts.isEmpty, texts.count <= EmbeddingConfiguration.maximumBatchCount,
              texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.utf8.count <= EmbeddingConfiguration.maximumInputBytes }) else {
            throw EmbeddingRuntimeError.invalidInput
        }
        let id = UUID()
        let cancellation = ModelVerification()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try cancellation.checkCancellation()
                        guard !stopped else { throw EmbeddingRuntimeError.stopped }
                        discardCancelledPending()
                        pending.append(Request(id: id, texts: texts, kind: kind,
                                               cancellation: cancellation, continuation: continuation))
                        startNext()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { [self] in
            // Per-call state closes cancellation-before-enqueue without retaining finished IDs.
            cancellation.cancel()
            queue.async { [self] in cancel(id) }
        })
    }

    /// Stop outstanding work and immediately release the worker, while permitting future use.
    public func unload() {
        synchronized { stopAll(error: CancellationError()) }
    }

    /// Synchronous, bounded shutdown is safe from applicationWillTerminate.
    public func shutdown() {
        synchronized {
            stopped = true
            stopAll(error: EmbeddingRuntimeError.stopped)
        }
    }

    public var isRunning: Bool { synchronized { run?.process.isRunning == true } }

    private func synchronized<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }

    private func startNext() {
        guard active == nil, !stopped else { return }
        idle?.cancel()
        idle = nil
        discardCancelledPending()
        guard !pending.isEmpty else {
            scheduleIdleUnload()
            return
        }
        // A user query runs after the current item and ahead of queued background documents.
        let next = pending.firstIndex { $0.kind == .query } ?? 0
        active = pending.remove(at: next)
        guard let request = active else { return }
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let self, let request, self.active?.id == request.id else { return }
            self.stopWorker()
            self.finishActive(.failure(EmbeddingRuntimeError.timedOut))
        }
        request.timeout = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        do {
            let model = try access.enabledEmbedding()
            if let run, run.model.modelKey != model.modelKey || run.model.fileURL != model.fileURL {
                stopWorker()
            }
            if let run, run.ready {
                send(request, to: run)
            } else {
                try startWorker(model: model)
            }
        } catch {
            stopWorker()
            finishActive(.failure(error))
        }
    }

    private func startWorker(model: InstalledEmbeddingModel) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EmbeddingRuntimeError.runtimeMissing
        }
        let next = Run(model: model)
        run = next
        startAvailabilityTimer()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                _ = try ModelStorage.verify(model.fileURL, descriptor: model.descriptor, token: next.verification)
            }
            self?.queue.async { [weak self] in
                guard let self, self.run?.id == next.id else { return }
                do {
                    try result.get()
                    let available = try self.access.enabledEmbedding()
                    guard available.modelKey == model.modelKey, available.fileURL == model.fileURL else {
                        throw EmbeddingRuntimeError.unavailable
                    }
                    try self.launch(next)
                } catch {
                    self.stopWorker()
                    self.finishActive(.failure(error))
                }
            }
        }
    }

    private func launch(_ next: Run) throws {
        next.process.executableURL = executable
        next.process.arguments = [next.model.fileURL.path]
        next.process.standardInput = next.input
        next.process.standardOutput = next.output
        next.process.standardError = FileHandle.nullDevice
        // Closing a worker during a large pipe write must throw EPIPE, not terminate the app.
        _ = fcntl(next.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let handle = next.output.fileHandleForReading
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        reader.setEventHandler { [weak self, weak next] in
            guard let self, let next, self.run?.id == next.id else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                self.receive(Data(buffer.prefix(count)), from: next)
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                self.workerFailed(next)
            }
        }
        // Dispatch closes only after the last event handler, avoiding close/read descriptor races.
        reader.setCancelHandler { try? handle.close() }
        next.reader = reader
        reader.resume()
        next.process.terminationHandler = { [weak self, weak next] _ in
            guard let next else { return }
            self?.queue.async { [weak self] in self?.workerFailed(next) }
        }
        try next.process.run()
        // Close the parent's copies of the child's pipe ends so EOF is observable.
        try? next.input.fileHandleForReading.close()
        try? next.output.fileHandleForWriting.close()
        next.ready = true
        if let active { send(active, to: next) }
    }

    private func send(_ request: Request, to worker: Run) {
        do {
            _ = try access.enabledEmbedding()
            let body = try JSONEncoder().encode(WireRequest(
                id: request.id.uuidString, kind: request.kind, texts: request.texts
            ))
            guard body.count <= Self.maximumFrame else { throw EmbeddingRuntimeError.invalidInput }
            var size = UInt32(body.count).bigEndian
            var frame = withUnsafeBytes(of: &size) { Data($0) }
            frame.append(body)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do { try worker.input.fileHandleForWriting.write(contentsOf: frame) }
                catch {
                    self?.queue.async { [weak self] in self?.workerFailed(worker) }
                }
            }
        } catch {
            stopWorker()
            finishActive(.failure(error))
        }
    }

    private func receive(_ bytes: Data, from worker: Run) {
        guard run?.id == worker.id else { return }
        guard !bytes.isEmpty else { workerFailed(worker); return }
        worker.received.append(bytes)
        guard worker.received.count <= Self.maximumFrame + 4 else {
            stopWorker()
            finishActive(.failure(EmbeddingRuntimeError.invalidResponse))
            return
        }
        guard worker.received.count >= 4 else { return }
        let size = worker.received.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= Self.maximumFrame else {
            stopWorker()
            finishActive(.failure(EmbeddingRuntimeError.invalidResponse))
            return
        }
        guard worker.received.count >= Int(size) + 4 else { return }
        do {
            guard worker.received.count == Int(size) + 4, let request = active else {
                throw EmbeddingRuntimeError.invalidResponse
            }
            let response = try JSONDecoder().decode(WireResponse.self, from: worker.received.dropFirst(4))
            worker.received.removeAll(keepingCapacity: true)
            guard response.id == request.id.uuidString else { throw EmbeddingRuntimeError.invalidResponse }
            let current = try access.enabledEmbedding()
            guard current.modelKey == worker.model.modelKey else { throw EmbeddingRuntimeError.unavailable }
            if let message = response.error {
                guard message.utf8.count <= 512 else { throw EmbeddingRuntimeError.invalidResponse }
                finishActive(.failure(EmbeddingRuntimeError.worker(message)))
                return
            }
            guard let outputs = response.outputs, outputs.count == request.texts.count,
                  outputs.allSatisfy({ Self.valid($0, kind: request.kind) }) else {
                throw EmbeddingRuntimeError.invalidResponse
            }
            finishActive(.success(outputs))
        } catch {
            stopWorker()
            finishActive(.failure(error))
        }
    }

    private static func valid(_ output: EmbeddingOutput, kind: EmbeddingInputKind) -> Bool {
        guard !output.vectors.isEmpty, output.vectors.count <= EmbeddingConfiguration.maximumDocumentChunks,
              kind != .query || (output.vectors.count == 1 && !output.truncated) else { return false }
        return output.vectors.allSatisfy { vector in
            guard vector.count == EmbeddingConfiguration.dimensions, vector.allSatisfy(\.isFinite) else {
                return false
            }
            let norm = vector.reduce(Double(0)) { $0 + Double($1) * Double($1) }
            return abs(norm - 1) < 0.01
        }
    }

    private func finishActive(_ result: Result<[EmbeddingOutput], Error>) {
        let finished = active
        active = nil
        finished?.timeout?.cancel()
        finished?.finish(result)
        startNext()
    }

    private func workerFailed(_ worker: Run) {
        guard run?.id == worker.id else { return }
        stopWorker()
        if active != nil { finishActive(.failure(EmbeddingRuntimeError.invalidResponse)) }
    }

    private func cancel(_ id: UUID) {
        if let active, active.id == id {
            if active.kind == .query {
                // Queries are short, bounded inputs. Finish the caller immediately, then
                // consume and discard this response so the next query reuses loaded weights.
                // Its existing deadline still kills a stuck worker.
                active.finish(.failure(CancellationError()))
            } else {
                stopWorker()
                finishActive(.failure(CancellationError()))
            }
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).finish(.failure(CancellationError()))
        }
    }

    private func discardCancelledPending() {
        pending.removeAll { request in
            guard request.isCancelled else { return false }
            request.finish(.failure(CancellationError()))
            return true
        }
    }

    private func startAvailabilityTimer() {
        availabilityTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let model = try self.access.enabledEmbedding()
                guard model.modelKey == self.run?.model.modelKey else {
                    throw EmbeddingRuntimeError.unavailable
                }
            } catch { self.stopAll(error: error) }
        }
        availabilityTimer = timer
        timer.resume()
    }

    private func scheduleIdleUnload() {
        guard run != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.active == nil else { return }
            self.stopWorker()
        }
        idle = item
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private func stopWorker() {
        idle?.cancel()
        idle = nil
        availabilityTimer?.cancel()
        availabilityTimer = nil
        guard let previous = run else { return }
        run = nil
        previous.verification.cancel()
        previous.reader?.cancel()
        previous.reader = nil
        previous.process.terminationHandler = nil
        if previous.process.isRunning { Darwin.kill(previous.process.processIdentifier, SIGKILL) }
        try? previous.input.fileHandleForWriting.close()
    }

    private func stopAll(error: Error) {
        stopWorker()
        let requests = (active.map { [$0] } ?? []) + pending
        active = nil
        pending.removeAll()
        for request in requests {
            request.timeout?.cancel()
            request.finish(.failure(error))
        }
    }
}
