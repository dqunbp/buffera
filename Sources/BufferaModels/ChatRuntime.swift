import Darwin
import Foundation

/// A reusable, local process owns all model and GPU memory. The serial queue only handles
/// state transitions; hashing and pipe writes never prevent cancellation or shutdown.
public final class ChatRuntime: @unchecked Sendable {
    private final class Request {
        let id: UUID
        let messages: [ChatMessage]
        let maximumTokens: Int
        let responseFormat: ChatResponseFormat
        let onToken: @Sendable (String) -> Void
        let continuation: CheckedContinuation<ChatGeneration, Error>
        var text = ""
        var timeout: DispatchWorkItem?

        init(id: UUID, messages: [ChatMessage], maximumTokens: Int, responseFormat: ChatResponseFormat,
             onToken: @escaping @Sendable (String) -> Void,
             continuation: CheckedContinuation<ChatGeneration, Error>) {
            self.id = id
            self.messages = messages
            self.maximumTokens = maximumTokens
            self.responseFormat = responseFormat
            self.onToken = onToken
            self.continuation = continuation
        }
    }

    private final class Run {
        let id = UUID()
        let model: InstalledAssistantModel
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let verification = ModelVerification()
        var reader: DispatchSourceRead?
        var ready = false
        var received = Data()

        init(model: InstalledAssistantModel) { self.model = model }
    }

    private struct WireRequest: Encodable {
        let id: String
        let messages: [ChatMessage]
        let maximumTokens: Int
        let responseFormat: ChatResponseFormat
    }

    private struct WireResponse: Decodable {
        let id: String
        let event: String
        let text: String?
        let stopReason: ChatStopReason?
        let inputTokens: Int?
        let outputTokens: Int?
        let error: String?
        let code: String?
    }

    private static let maximumFrame = 1024 * 1024
    private static let maximumOutputBytes = 128 * 1024
    private let queue = DispatchQueue(label: "app.buffera.chat", qos: .utility)
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
                requestTimeout: TimeInterval = 240,
                descriptor: LocalModelDescriptor = LocalModelCatalog.models.first { $0.role == .assistant }!) {
        access = LocalModelReadAccess(rootURL: modelRootURL, descriptor: descriptor)
        executable = executableURL ?? bundleURL.appendingPathComponent("Contents/MacOS/BufferaChatWorker")
        self.idleTimeout = max(0.05, idleTimeout)
        self.requestTimeout = max(0.05, requestTimeout)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { shutdown() }

    /// The callback receives ordered, complete UTF-8 text fragments on a private queue.
    public func generate(messages: [ChatMessage], maximumTokens: Int = 1024,
                         responseFormat: ChatResponseFormat = .text,
                         onToken: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ChatGeneration {
        try Task.checkCancellation()
        guard maximumTokens > 0, maximumTokens <= ChatConfiguration.maximumOutputTokens,
              Self.valid(messages) else {
            throw ChatRuntimeError.invalidInput
        }
        guard messages.count <= ChatConfiguration.maximumMessages,
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= ChatConfiguration.maximumInputBytes else {
            throw ChatRuntimeError.contextTooLong
        }
        let id = UUID()
        let cancellation = ModelVerification()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try cancellation.checkCancellation()
                        guard !stopped else { throw ChatRuntimeError.stopped }
                        pending.append(Request(id: id, messages: messages, maximumTokens: maximumTokens,
                                               responseFormat: responseFormat, onToken: onToken,
                                               continuation: continuation))
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
            stopAll(error: ChatRuntimeError.stopped)
        }
    }

    public var isRunning: Bool { synchronized { run?.process.isRunning == true } }

    private static func valid(_ messages: [ChatMessage]) -> Bool {
        guard !messages.isEmpty,
              messages.last?.role == .user,
              messages.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }
        var expected = ChatRole.user
        for (index, message) in messages.enumerated() {
            if index == 0 && message.role == .system { continue }
            guard message.role == expected else { return false }
            expected = expected == .user ? .assistant : .user
        }
        return true
    }

    private func synchronized<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }

    private func startNext() {
        guard active == nil, !stopped else { return }
        idle?.cancel()
        idle = nil
        guard !pending.isEmpty else {
            scheduleIdleUnload()
            return
        }
        active = pending.removeFirst()
        guard let request = active else { return }
        let timeout = DispatchWorkItem { [weak self, weak request] in
            guard let self, let request, self.active?.id == request.id else { return }
            self.stopWorker()
            self.finishActive(.failure(ChatRuntimeError.timedOut))
        }
        request.timeout = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        do {
            let model = try access.enabledAssistant()
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

    private func startWorker(model: InstalledAssistantModel) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ChatRuntimeError.runtimeMissing
        }
        let next = Run(model: model)
        run = next
        startAvailabilityTimer()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try ModelStorage.verify(model.fileURL, descriptor: model.descriptor, token: next.verification)
            }
            self?.queue.async { [weak self] in
                guard let self, self.run?.id == next.id else { return }
                do {
                    try result.get()
                    let available = try self.access.enabledAssistant()
                    guard available.modelKey == model.modelKey, available.fileURL == model.fileURL else {
                        throw ChatRuntimeError.unavailable
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
            _ = try access.enabledAssistant()
            let body = try JSONEncoder().encode(WireRequest(
                id: request.id.uuidString, messages: request.messages, maximumTokens: request.maximumTokens,
                responseFormat: request.responseFormat
            ))
            guard body.count <= Self.maximumFrame else { throw ChatRuntimeError.invalidInput }
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
        guard worker.received.count <= Self.maximumFrame + 64 * 1024 + 4 else {
            stopWorker()
            finishActive(.failure(ChatRuntimeError.invalidResponse))
            return
        }
        do {
            // Pipe reads may contain half a frame or several streamed events at once.
            while run?.id == worker.id, worker.received.count >= 4 {
                let size = worker.received.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size > 0, size <= Self.maximumFrame else { throw ChatRuntimeError.invalidResponse }
                guard worker.received.count >= Int(size) + 4 else { return }
                let frame = Data(worker.received.dropFirst(4).prefix(Int(size)))
                worker.received.removeFirst(Int(size) + 4)
                let response = try JSONDecoder().decode(WireResponse.self, from: frame)
                guard let request = active, response.id == request.id.uuidString else {
                    throw ChatRuntimeError.invalidResponse
                }
                let current = try access.enabledAssistant()
                guard current.modelKey == worker.model.modelKey else { throw ChatRuntimeError.unavailable }
                switch response.event {
                case "delta":
                    guard let text = response.text, !text.isEmpty,
                          request.text.utf8.count + text.utf8.count <= Self.maximumOutputBytes,
                          response.error == nil else { throw ChatRuntimeError.invalidResponse }
                    request.text += text
                    request.onToken(text)
                case "done":
                    guard let reason = response.stopReason,
                          let input = response.inputTokens, input > 0,
                          input <= ChatConfiguration.maximumPromptTokens,
                          let output = response.outputTokens, output >= 0, output <= request.maximumTokens,
                          response.error == nil else { throw ChatRuntimeError.invalidResponse }
                    if request.responseFormat == .json && reason == .completed {
                        guard let bytes = request.text.data(using: .utf8),
                              (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else {
                            throw ChatRuntimeError.invalidResponse
                        }
                    }
                    finishActive(.success(ChatGeneration(text: request.text, stopReason: reason,
                                                         inputTokens: input, outputTokens: output)))
                case "error":
                    guard let message = response.error, message.utf8.count <= 512 else {
                        throw ChatRuntimeError.invalidResponse
                    }
                    let error: Error = response.code == "context_too_long"
                        ? ChatRuntimeError.contextTooLong : ChatRuntimeError.worker(message)
                    finishActive(.failure(error))
                default: throw ChatRuntimeError.invalidResponse
                }
            }
        } catch {
            stopWorker()
            finishActive(.failure(error))
        }
    }

    private func finishActive(_ result: Result<ChatGeneration, Error>) {
        let finished = active
        active = nil
        finished?.timeout?.cancel()
        finished?.continuation.resume(with: result)
        startNext()
    }

    private func workerFailed(_ worker: Run) {
        guard run?.id == worker.id else { return }
        stopWorker()
        if active != nil { finishActive(.failure(ChatRuntimeError.invalidResponse)) }
    }

    private func cancel(_ id: UUID) {
        if active?.id == id {
            stopWorker()
            finishActive(.failure(CancellationError()))
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func startAvailabilityTimer() {
        availabilityTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let model = try self.access.enabledAssistant()
                guard model.modelKey == self.run?.model.modelKey else {
                    throw ChatRuntimeError.unavailable
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
            request.continuation.resume(throwing: error)
        }
    }
}
