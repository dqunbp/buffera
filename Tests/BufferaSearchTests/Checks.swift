import Foundation
import BufferaCore
import BufferaModels
import BufferaSearch

struct CheckFailure: Error { let message: String }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(message: message) }
}
func eventually(_ condition: () throws -> Bool) async throws {
    for _ in 0..<200 {
        if try condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CheckFailure(message: "Timed out waiting for durable index state")
}

actor Inference {
    var calls = 0
    var failing = false
    var delay: UInt64 = 0
    func configure(failing: Bool = false, delay: UInt64 = 0) {
        self.failing = failing; self.delay = delay
    }
    func embed(_ text: String) async throws -> EmbeddingOutput {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failing { throw CheckFailure(message: "Fixture inference failure") }
        return EmbeddingOutput(vectors: [[1, 0, 0]], truncated: false)
    }
}

@main struct Checks {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--live" {
            try await runLiveSearchChecks(arguments: CommandLine.arguments)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BufferaSearchChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(url: database)
        func insert(_ text: String) throws -> Int64 {
            try store.insert(payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text",
                data: Data(text.utf8))]]), kind: .text, title: text, text: text, source: "Fixture",
                isConcealed: false, date: Date(), maxCount: 100, maxBytes: 1_000_000)
        }
        let one = try insert("PostgreSQL connection refused")
        let inference = Inference()
        let identity = EmbeddingIndexIdentity(fingerprint: "fixture", dimensions: 3)
        let indexer = EmbeddingIndexer(databaseURL: database, identity: identity,
            documentProvider: { try await inference.embed($0) }, onProgress: { _ in }, onIndexed: {})
        defer { indexer.shutdown() }
        await indexer.setEnabled(true)
        try await eventually { try store.embeddingProgress().complete == 1 }
        let service = HybridSearchService(queryProvider: { _ in SemanticQuery(vector: [1, 0, 0], identity: identity) })
        var filter = SearchFilter()
        filter.query = "ошибка базы"
        let found = try await service.search(databaseURL: database, filter: filter)
        try require(found.mode == .hybrid && found.rows.map(\.id) == [one], "Shared search returns indexed document")

        // Disabling preserves completed vectors; pending documents resume after re-enable.
        await indexer.setEnabled(false)
        let two = try insert("Second pending record")
        await indexer.schedule()
        try require(try store.embeddingProgress().complete == 1, "Disabled indexer must not process")
        await indexer.setEnabled(true)
        try await eventually { try store.embeddingProgress().complete == 2 }
        try require(await inference.calls == 2, "Resume must not recompute complete documents")

        // A failure pauses the drain and retry explicitly restarts it.
        await inference.configure(failing: true)
        _ = try insert("Failed document")
        await indexer.schedule()
        try await eventually { try store.embeddingProgress().failed == 1 }
        let callsAtFailure = await inference.calls
        await indexer.schedule()
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(await inference.calls == callsAtFailure, "Failure must not spin")
        await inference.configure()
        await indexer.retry()
        try await eventually { try store.embeddingProgress().complete == 3 }

        // An in-flight completion cannot resurrect a concealed record.
        await inference.configure(delay: 150_000_000)
        let hidden = try insert("Hide while inference is running")
        await indexer.schedule()
        try await Task.sleep(nanoseconds: 40_000_000)
        try store.conceal(id: hidden)
        try await Task.sleep(nanoseconds: 180_000_000)
        try require(try store.embeddingProgress().complete == 3, "Conceal must reject late completion")

        // Cancel in-flight work, retain a durable pending job, then resume.
        _ = try insert("Cancellation document")
        await indexer.schedule()
        try await Task.sleep(nanoseconds: 40_000_000)
        await indexer.setEnabled(false)
        try require(try store.embeddingProgress().pending == 1, "Cancellation must preserve pending job")
        await inference.configure()
        await indexer.setEnabled(true)
        try await eventually { try store.embeddingProgress().complete == 4 }
        try store.delete(id: two)
        let refreshed = try await service.search(databaseURL: database, filter: filter)
        try require(!refreshed.rows.contains { $0.id == two || $0.id == hidden }, "Search revalidates removed and hidden records")
        await indexer.setEnabled(false)
        await inference.configure(delay: 150_000_000)
        _ = try insert("Pending across application shutdown")
        await indexer.setEnabled(true)
        try await Task.sleep(nanoseconds: 40_000_000)
        indexer.shutdown()
        try await Task.sleep(nanoseconds: 180_000_000)
        try require(try store.embeddingProgress().pending == 1, "Shutdown preserves unfinished work")
        try require(try store.embeddingProgress().failed == 0, "Shutdown must not record an inference failure")
        let stoppedCalls = await inference.calls
        await indexer.schedule()
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(await inference.calls == stoppedCalls, "Shutdown cannot be restarted")
        print("PASS: index lifecycle, resume, retry, cancellation, conceal race, shutdown, shared search")
    }
}
