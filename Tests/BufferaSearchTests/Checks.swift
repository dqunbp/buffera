import Foundation
import BufferaLocalization
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
    var stoppedCalls = 0
    var failing = false
    var delay: UInt64 = 0
    private var shouldStopNext = false
    func configure(failing: Bool = false, delay: UInt64 = 0) {
        self.failing = failing; self.delay = delay
    }
    func stopNextRequest() { shouldStopNext = true }
    func embed(_ text: String) async throws -> EmbeddingOutput {
        calls += 1
        let stop = shouldStopNext
        shouldStopNext = false
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if stop {
            stoppedCalls += 1
            throw EmbeddingRuntimeError.stopped
        }
        if failing { throw CheckFailure(message: "Fixture inference failure") }
        return EmbeddingOutput(vectors: [[1, 0, 0]], truncated: false)
    }
}

private final class IndexStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = EmbeddingIndexStatus.disabled
    func record(_ value: EmbeddingIndexStatus) {
        lock.lock(); self.value = value; lock.unlock()
    }
    var latest: EmbeddingIndexStatus {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

private func checkPreparationPauses(root: URL) async throws {
    let database = root.appendingPathComponent("paused-history.sqlite")
    let store = try HistoryStore(url: database)
    func insert(_ text: String) throws {
        _ = try store.insert(payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text",
            data: Data(text.utf8))]]), kind: .text, title: text, text: text, source: "Fixture",
            isConcealed: false, date: Date(), maxCount: 100, maxBytes: 1_000_000)
    }
    try insert("First battery document")
    try insert("Second battery document")
    let inference = Inference()
    let status = IndexStatusRecorder()
    let indexer = EmbeddingIndexer(databaseURL: database,
        identity: EmbeddingIndexIdentity(fingerprint: "pause-fixture", dimensions: 3),
        documentProvider: { try await inference.embed($0) },
        onProgress: { status.record($0) }, onIndexed: {})
    defer { indexer.shutdown() }

    // Applying the startup policy before enabling must queue work without launching inference.
    await indexer.setPaused(reason: .battery)
    await indexer.setEnabled(true)
    try require(await inference.calls == 0, "Initial battery policy must precede inference")
    try require(try store.embeddingProgress().pending == 2, "Battery pause must retain durable pending jobs")
    try require(status.latest.pauseReason == .battery && status.latest.canContinueNow &&
                status.latest.message.contains(L10n.language == "ru" ? "осталось: 2" : "remaining: 2"),
                "Battery pause must expose its reason and remaining count")
    await indexer.schedule()
    try require(await inference.calls == 0, "Repeated schedule cannot bypass the power policy")

    await inference.configure(delay: 150_000_000)
    await indexer.setPaused(reason: nil)
    for _ in 0..<100 {
        if await inference.calls == 1 { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try require(await inference.calls == 1, "Resuming did not start the pending document")
    await indexer.setPaused(reason: .foregroundChat)
    try await eventually { try store.embeddingProgress().complete == 1 }
    try await Task.sleep(nanoseconds: 30_000_000)
    try require(await inference.calls == 1 && (try store.embeddingProgress().pending) == 1,
                "A pause must finish the active document without dequeuing another")
    try require(try store.embeddingProgress().failed == 0,
                "Pausing active preparation must not mark a job failed")
    try require(status.latest.pauseReason == .foregroundChat && !status.latest.canContinueNow,
                "Interactive priority pause cannot offer a battery override")
    await indexer.setPaused(reason: .lowPowerMode)
    try require(status.latest.pauseReason == .lowPowerMode && !status.latest.canContinueNow,
                "Low Power Mode must remain distinguishable from a battery preference")

    await indexer.setEnabled(false)
    await indexer.setEnabled(true)
    try require(await inference.calls == 1 && (try store.embeddingProgress().pending) == 1,
                "Re-enabling a feature cannot bypass an active pause")
    await inference.configure()
    await indexer.setPaused(reason: nil)
    try await eventually { try store.embeddingProgress().complete == 2 }
    try require(await inference.calls == 2, "Resume recomputed an already completed document")
    await indexer.setPaused(reason: .battery)
    try insert("Captured while preparation is paused")
    await indexer.schedule()
    try require(status.latest.message.contains(L10n.language == "ru" ? "осталось: 1" : "remaining: 1") &&
                (try store.embeddingProgress().pending) == 1,
                "New captures must update the pending count while preparation is paused")

    // Model availability can interrupt a suspended request before the actor receives OFF.
    // Reasserting ON must restart that drain rather than trusting the stale enabled flag.
    await inference.configure(delay: 50_000_000)
    await inference.stopNextRequest()
    await indexer.setPaused(reason: nil)
    for _ in 0..<100 {
        if await inference.stoppedCalls == 1 { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try require(await inference.stoppedCalls == 1, "Fixture did not interrupt the previous drain")
    let interrupted = try store.embeddingProgress()
    try require(interrupted.pending == 1 && interrupted.failed == 0,
                "Interrupted runtime must preserve the pending document")
    await inference.configure()
    await indexer.setEnabled(true)
    try await eventually { try store.embeddingProgress().complete == 3 }
    try require(await inference.calls == 4, "Reasserted enable must resume the interrupted pending document once")

    // An injected runtime belongs to the application, including after indexer shutdown.
    let shared = EmbeddingRuntime(modelRootURL: root)
    defer { shared.shutdown() }
    let sharedIndexer = EmbeddingIndexer(databaseURL: database, modelRootURL: root, embeddingRuntime: shared,
        onProgress: { _ in }, onIndexed: {})
    sharedIndexer.shutdown()
    do {
        _ = try await shared.embed(["Check shared ownership"], kind: .query)
        throw CheckFailure(message: "An absent test model unexpectedly embedded a query")
    } catch EmbeddingRuntimeError.stopped {
        throw CheckFailure(message: "Indexer shutdown permanently stopped its shared runtime")
    } catch EmbeddingRuntimeError.unavailable {
        // Missing fixture files are expected; the runtime still accepted the request.
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
        try await checkPreparationPauses(root: root)
        print("PASS: index lifecycle, pause policy, resume, retry, cancellation, conceal race, shutdown, shared search")
    }
}
