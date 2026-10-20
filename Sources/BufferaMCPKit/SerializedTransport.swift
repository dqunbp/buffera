import Foundation
import Logging
import MCP

/// Keeps a complete JSON-RPC message together even when the underlying actor yields during a write.
/// One instance owns one connection; disconnect closes it permanently and cancels all pending sends.
public actor SerializedTransport: Transport {
    public nonisolated let logger = Logger(label: "buffera.mcp.serialized-transport",
                                    factory: { _ in SwiftLogNoOpLogHandler() })

    private typealias Messages = AsyncThrowingStream<Data, Swift.Error>
    private let underlying: any Transport
    private var connection: Task<Messages, Error>?
    private var messages: Messages?
    private var closed = false
    private var tail: (id: UUID, task: Task<Void, Error>)?
    private var sends: [UUID: Task<Void, Error>] = [:]

    public init(_ underlying: any Transport) {
        self.underlying = underlying
    }

    public func connect() async throws {
        guard !closed else { throw CancellationError() }
        if messages != nil { return }
        if connection == nil {
            let transport = underlying
            connection = Task {
                do {
                    try await transport.connect()
                    try Task.checkCancellation()
                    let stream = await transport.receive()
                    try Task.checkCancellation()
                    return stream
                } catch {
                    await transport.disconnect()
                    throw error
                }
            }
        }
        guard let connection else { throw CancellationError() }
        do {
            let stream = try await connection.value
            guard !closed else { throw CancellationError() }
            messages = stream
        } catch {
            await disconnect()
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !closed, messages != nil else { throw CancellationError() }
        let previous = tail?.task
        let transport = underlying
        let id = UUID()
        // Tasks retain only their predecessor and underlying transport, never this wrapper.
        let task = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await transport.send(data)
        }
        tail = (id, task)
        sends[id] = task
        defer {
            sends[id] = nil
            if tail?.id == id { tail = nil }
        }
        do {
            try await task.value
        } catch {
            // A failed write may have emitted only part of a JSON message. Do not append another.
            await disconnect()
            throw error
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messages ?? AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }

    public func disconnect() async {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        for task in sends.values { task.cancel() }
        sends.removeAll()
        tail = nil
        await underlying.disconnect()
    }
}
