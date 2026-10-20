import Foundation
import Logging
import MCP

/// SDK 0.12.1 interprets data: URL strings as binary values during type erasure.
/// Preserve tool arguments as JSON text until our handler, and rebuild structured results from
/// their exact JSON text fallback after SDK encoding. Protocol dispatch stays in the SDK.
actor LiteralJSONTransport: Transport {
    nonisolated let logger = Logger(label: "buffera.mcp.literal-json",
                                    factory: { _ in SwiftLogNoOpLogHandler() })
    private let underlying: any Transport
    private let messages: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var relay: Task<Void, Never>?
    private var closed = false

    init(_ underlying: any Transport) {
        self.underlying = underlying
        let pair = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        messages = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws {
        guard !closed else { throw CancellationError() }
        guard relay == nil else { return }
        try await underlying.connect()
        let source = await underlying.receive()
        guard !closed else { throw CancellationError() }
        let destination = continuation
        relay = Task.detached {
            do {
                for try await message in source {
                    try Task.checkCancellation()
                    destination.yield(Self.rewrite(message, incoming: true))
                }
                destination.finish()
            } catch {
                destination.finish(throwing: error)
            }
        }
    }

    func send(_ data: Data) async throws {
        try await underlying.send(Self.rewrite(data, incoming: false))
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { messages }

    func disconnect() async {
        guard !closed else { return }
        closed = true
        relay?.cancel()
        relay = nil
        continuation.finish()
        await underlying.disconnect()
    }

    private nonisolated static func rewrite(_ data: Data, incoming: Bool) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return data }
        func message(_ value: Any) -> Any {
            guard var envelope = value as? [String: Any] else { return value }
            if incoming {
                guard envelope["method"] as? String == LiteralCallTool.name,
                      var parameters = envelope["params"] as? [String: Any],
                      let arguments = try? JSONSerialization.data(
                        withJSONObject: parameters["arguments"] ?? NSNull(),
                        options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return value }
                // Always overwrite this internal field; clients cannot inject a pre-tunnelled value.
                parameters["bufferaArgumentsJSON"] = String(decoding: arguments, as: UTF8.self)
                parameters.removeValue(forKey: "arguments")
                envelope["params"] = parameters
            } else {
                guard var result = envelope["result"] as? [String: Any],
                      result["isError"] as? Bool == false,
                      let content = result["content"] as? [[String: Any]], content.count == 1,
                      content[0]["type"] as? String == "text",
                      let text = content[0]["text"] as? String,
                      let structured = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                      structured is [String: Any] else { return value }
                result["structuredContent"] = structured
                envelope["result"] = result
            }
            return envelope
        }
        let rewritten: Any
        if let batch = object as? [Any] { rewritten = batch.map(message) }
        else { rewritten = message(object) }
        return (try? JSONSerialization.data(withJSONObject: rewritten,
                                            options: [.sortedKeys, .withoutEscapingSlashes])) ?? data
    }
}

/// Matches the public tools/call method; only the internal parameter representation differs.
enum LiteralCallTool: MCP.Method {
    static let name = CallTool.name
    typealias Result = CallTool.Result

    struct Parameters: Codable, Hashable, Sendable {
        let name: String
        let bufferaArgumentsJSON: String

        func arguments() throws -> [String: Value]? {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(bufferaArgumentsJSON.utf8), options: .fragmentsAllowed) else {
                throw MCPError.invalidParams("arguments: ожидается JSON-объект.")
            }
            if object is NSNull { return nil }
            guard let dictionary = object as? [String: Any] else {
                throw MCPError.invalidParams("arguments: ожидается JSON-объект.")
            }
            return dictionary.mapValues(MCPJSON.value)
        }
    }
}
