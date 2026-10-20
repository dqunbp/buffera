import Foundation
import Darwin
import BufferaCore

/// Uses Foundation JSON and raw pipes so the SDK client's own Value decoder cannot mask regressions.
func runRawJSONChecks() async throws {
    try await Task.detached {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        try fixture.access.setEnabled(true)
        let literals = [
            "data:text/plain;charset=utf-8,hello%20percent",
            "data:;base64,YmFzZTY0",
            "data:text/plain,hello space",
            "data:application/json,%7b%22x%22%3a1%7d"
        ]
        var ids: [Int64] = []
        for text in literals {
            ids.append(try fixture.store.insert(
                payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]]),
                kind: .text, title: text, text: text, source: text))
        }
        let connection = try RawJSONConnection(directory: fixture.directory)
        defer { connection.close() }
        for (text, id) in zip(literals, ids) {
            let search = try connection.call("search_history", arguments: ["query": text])
            let searchResult = search["result"] as? [String: Any]
            let structured = searchResult?["structuredContent"] as? [String: Any]
            try checkEqual(structured?["total"] as? Int, 1)
            let items = structured?["items"] as? [[String: Any]]
            try checkEqual(items?.first?["title"] as? String, text)
            try checkEqual(items?.first?["snippet"] as? String, text)
            try checkEqual(items?.first?["source"] as? String, text)
            let read = try connection.call("read_clip", arguments: ["id": String(id)])
            let result = read["result"] as? [String: Any]
            let output = result?["structuredContent"] as? [String: Any]
            try checkEqual(output?["text"] as? String, text)
            let content = result?["content"] as? [[String: Any]]
            let fallback = try JSONSerialization.jsonObject(with: Data((content?.first?["text"] as? String ?? "").utf8)) as? [String: Any]
            try checkEqual(fallback?["text"] as? String, text)
        }
        let integral = try connection.callRawArguments(#"{"limit":1.0}"#)
        try checkEqual((integral["result"] as? [String: Any])?["isError"] as? Bool, false)
        let spoofed = try connection.request("tools/call", parameters: [
            "name": "search_history", "arguments": ["query": literals[0]],
            "bufferaArgumentsJSON": #"{"query":"unmatched injected query"}"#
        ])
        let spoofedResult = spoofed["result"] as? [String: Any]
        try checkEqual((spoofedResult?["structuredContent"] as? [String: Any])?["total"] as? Int, 1)
        for invalid in [#"{"limit":1.5}"#, #"{"limit":true}"#, #"{"include_hidden":true}"#, #"[]"#, #""data:text/plain,not an argument object""#] {
            let response = try connection.callRawArguments(invalid)
            try checkEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        let unknown = try connection.request("unknown/method", parameters: [:])
        try checkEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
        try fixture.access.setEnabled(false)
        let disabled = try connection.call("search_history", arguments: ["query": literals[0]])
        let disabledResult = disabled["result"] as? [String: Any]
        try checkEqual(disabledResult?["isError"] as? Bool, true)
        try checkNil(disabledResult?["structuredContent"])
        print("PASS: raw JSON preserves data URL queries and results, numeric types and errors")
    }.value
}

private final class RawJSONConnection: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var closed = false
    private var nextID = 0
    private var pending = Data()

    init(directory: URL) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = ProcessInfo.processInfo.environment["BUFFERA_MCP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/debug/BufferaMCP")
        process.arguments = ["--data-directory", directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Bound reads even if a protocol regression stops the helper from producing a response.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.lock.withLock({ self.closed }) else { return }
            if self.process.isRunning { self.process.terminate() }
        }
        do {
            let handshake = try request("initialize", parameters: [
                "protocolVersion": "2025-11-25", "capabilities": [String: String](),
                "clientInfo": ["name": "Buffera-raw-checks", "version": "1.0"]
            ])
            try checkNotNil(handshake["result"])
            try write(["jsonrpc": "2.0", "method": "notifications/initialized"])
        } catch {
            close()
            throw error
        }
    }

    func call(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        try request("tools/call", parameters: ["name": name, "arguments": arguments])
    }

    func callRawArguments(_ json: String) throws -> [String: Any] {
        nextID += 1
        let request = "{\"jsonrpc\":\"2.0\",\"id\":\(nextID),\"method\":\"tools/call\",\"params\":{\"name\":\"search_history\",\"arguments\":\(json)}}\n"
        try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        return try read(id: nextID)
    }

    func request(_ method: String, parameters: [String: Any]) throws -> [String: Any] {
        nextID += 1
        try write(["jsonrpc": "2.0", "id": nextID, "method": method, "params": parameters])
        return try read(id: nextID)
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func read(id: Int) throws -> [String: Any] {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                let response = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                if response?["id"] as? Int == id, let response { return response }
            } else {
                // FileHandle.read(upToCount:) can wait for the entire requested length.
                // A pipe response is often shorter: POSIX read returns the available bytes.
                var bytes = [UInt8](repeating: 0, count: 4_096)
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw RawJSONError.readFailure(errno) }
                guard count > 0 else { throw RawJSONError.unexpectedEOF }
                pending.append(contentsOf: bytes.prefix(count))
            }
        }
    }

    func close() {
        guard lock.withLock({ if closed { return false }; closed = true; return true }) else { return }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}

private enum RawJSONError: Error { case unexpectedEOF, readFailure(Int32) }
