import Foundation
import Darwin
import System
import MCP
import BufferaCore

/// A real SDK client launches the packaged entry point over pipes; it never opens the user's history.
final class StdioProcessTests {
    func testClientHandshakeToolsReadRevocationAndEOF() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        try await fixture.withConnection { connection in
            let (tools, cursor) = try await connection.client.listTools()
            try checkEqual(Set(tools.map(\.name)), ["search_history", "read_clip", "get_neighbors"])
            try checkNil(cursor)

            var result = try await connection.call("search_history", ["query": "Buffera MCP fixture"])
            try checkEqual(result.isError, true)
            try fixture.access.setEnabled(true)
            result = try await connection.call("search_history", ["query": "Buffera MCP fixture"])
            try checkEqual(result.isError, false)
            try checkEqual(result.structuredContent?.objectValue?["total"], 2)
            guard case .text(let json, _, _) = result.content.first else { return try checkFail("Missing JSON text fallback") }
            try checkEqual(try JSONDecoder().decode(Value.self, from: Data(json.utf8)), result.structuredContent)
            try checkFalse(json.contains("hidden-marker"))

            let read = try await connection.call("read_clip", ["id": .string(String(fixture.firstID)), "limit": 7])
            try checkEqual(read.structuredContent?.objectValue?["text"], "Buffera")
            try checkEqual(read.structuredContent?.objectValue?["next_offset"], 7)
            let neighbors = try await connection.call("get_neighbors", ["id": .string(String(fixture.firstID))])
            try checkEqual(neighbors.structuredContent?.objectValue?["items"]?.arrayValue?.count, 3)
            let hidden = try await connection.call("read_clip", ["id": .string(String(fixture.hiddenID))])
            try checkEqual(hidden.isError, false)
            try checkEqual(hidden.structuredContent?.objectValue?["content_kind"], "masked")
            try checkEqual(hidden.structuredContent?.objectValue?["text"], "")
            try checkNil(hidden.structuredContent?.objectValue?["total_characters"])
            let filtered = try await connection.call("search_history", ["concealed_only": true])
            try checkEqual(filtered.structuredContent?.objectValue?["total"], 1)
            try checkEqual(filtered.structuredContent?.objectValue?["items"]?.arrayValue?.first?.objectValue?["id"], .string(String(fixture.hiddenID)))
            do {
                _ = try await connection.call("reveal_clip", ["id": .string(String(fixture.hiddenID))])
                try checkFail("Removed reveal tool must reject direct calls")
            } catch let error as MCPError {
                guard case .invalidParams = error else { return try checkFail("Unexpected error: \(error)") }
            }

            do {
                _ = try await connection.call("search_history", ["include_hidden": true])
                try checkFail("Unknown arguments must not be ignored")
            } catch let error as MCPError {
                guard case .invalidParams = error else { return try checkFail("Unexpected error: \(error)") }
            }

            try fixture.access.setEnabled(false)
            let revoked = try await connection.call("read_clip", ["id": .string(String(fixture.firstID))])
            try checkEqual(revoked.isError, true)
            await connection.client.disconnect()
            try connection.input.fileHandleForWriting.close()
            for _ in 0..<100 where connection.process.isRunning {
                try await Task.sleep(for: .milliseconds(20))
            }
            try checkFalse(connection.process.isRunning, "stdin EOF should terminate the helper")
            if !connection.process.isRunning { try checkEqual(connection.process.terminationStatus, 0) }
        }
    }

    func testConcurrentLargeResponsesRemainSeparateJSONMessages() async throws {
        let fixture = try ProcessFixture()
        defer { fixture.cleanup() }
        try fixture.access.setEnabled(true)
        try await fixture.withConnection { connection in
            // Large visible responses and a masked response exercise concurrent transport framing.
            async let first = connection.call("read_clip", ["id": .string(String(fixture.firstID)), "limit": 32_000])
            async let second = connection.call("read_clip", ["id": .string(String(fixture.secondID)), "limit": 32_000])
            async let concealed = connection.call("read_clip", ["id": .string(String(fixture.hiddenID)), "limit": 32_000])
            let results = try await [first, second, concealed]
            try checkEqual(results[0].structuredContent?.objectValue?["text"]?.stringValue,
                           String(fixture.firstText.prefix(32_000)))
            try checkEqual(results[1].structuredContent?.objectValue?["text"]?.stringValue,
                           String(fixture.secondText.prefix(32_000)))
            try checkEqual(results[2].structuredContent?.objectValue?["text"]?.stringValue,
                           "")
            try checkEqual(results[2].structuredContent?.objectValue?["content_kind"], "masked")
        }
    }
}

final class ProcessFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BufferaStdio-\(UUID())")
    let access: MCPAccess
    let store: HistoryStore
    let firstText = "Buffera MCP fixture alpha\n" + String(repeating: "А", count: 60_000)
    let secondText = "Buffera MCP fixture beta\n" + String(repeating: "Б", count: 60_000)
    let hiddenText = "Buffera MCP fixture hidden-marker\n" + String(repeating: "С", count: 60_000)
    let firstID: Int64
    let secondID: Int64
    let hiddenID: Int64

    init() throws {
        access = MCPAccess(directory: directory)
        store = try makeTestHistoryStore(url: access.databaseURL)
        let writer = store
        func insert(_ text: String, hidden: Bool = false) throws -> Int64 {
            try writer.insert(payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]]),
                             kind: .text, title: String(text.prefix(40)), text: text, source: "MCP Test",
                             isConcealed: hidden)
        }
        firstID = try insert(firstText)
        secondID = try insert(secondText)
        hiddenID = try insert(hiddenText, hidden: true)
    }

    func connect() async throws -> ProcessConnection {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["BUFFERA_MCP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent(".build/debug/BufferaMCP")
        return try await ProcessConnection(executable: executable, directory: directory)
    }

    func withConnection(_ operation: (ProcessConnection) async throws -> Void) async throws {
        let connection = try await connect()
        do {
            try await operation(connection)
            await connection.cleanup()
        } catch {
            await connection.cleanup()
            throw error
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

final class ProcessConnection: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let client = Client(name: "Buffera-stdio-checks", version: "1.0", configuration: .strict)
    private let cleanupLock = NSLock()
    private var didCleanUp = false

    init(executable: URL, directory: URL) async throws {
        process.executableURL = executable
        process.arguments = ["--data-directory", directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Bound a broken handshake/response too, so protocol regressions cannot hang the suite.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.cleanupLock.withLock({ self.didCleanUp }) else { return }
            FileHandle.standardError.write(Data("FAIL: MCP process check exceeded 20 seconds.\n".utf8))
            if self.process.isRunning { self.process.terminate() }
            // Ending the child alone cannot unblock every SDK client failure (including EOF spins).
            exit(1)
        }
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: output.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: input.fileHandleForWriting.fileDescriptor))
        do {
            let initialized = try await client.connect(transport: transport)
            try checkEqual(initialized.serverInfo.name, "buffera")
            try checkNotNil(initialized.capabilities.tools)
        } catch {
            await cleanup()
            throw error
        }
    }

    func call(_ name: String, _ arguments: [String: Value]) async throws -> CallTool.Result {
        let request = CallTool.request(.init(name: name, arguments: arguments))
        let context = try await client.send(request)
        return try await context.value
    }

    func cleanup() async {
        // Stop the SDK reader before closing descriptors that a later fixture might reuse.
        await client.disconnect()
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
        cleanupLock.withLock { didCleanUp = true }
    }
}

func runStdioProcessChecks() async throws {
    let checks = StdioProcessTests()
    try await checks.testClientHandshakeToolsReadRevocationAndEOF()
    print("PASS MCP client handshake, tools, revocation and EOF")
    try await checks.testConcurrentLargeResponsesRemainSeparateJSONMessages()
    print("PASS concurrent MCP responses preserve framing")
}
