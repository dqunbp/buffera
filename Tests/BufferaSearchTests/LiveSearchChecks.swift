import BufferaCore
import BufferaModels
import BufferaSearch
import Foundation

/// Exercises the production indexer, worker, vector store, and search service with
/// synthetic clipboard records and an isolated model receipt. No user history is opened.
func runLiveSearchChecks(arguments: [String]) async throws {
    guard arguments.count == 4 else {
        throw CheckFailure(message:
            "Usage: BufferaSearchChecks --live /absolute/Buffera.app /absolute/model.gguf")
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BufferaLiveSearchChecks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = LocalModelCatalog.models.first { $0.role == .embedding }!
    let modelRoot = root.appendingPathComponent("Models")
    let modelDirectory = modelRoot.appendingPathComponent("embedding")
        .appendingPathComponent(descriptor.revision)
    try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[3]),
                                    to: modelDirectory.appendingPathComponent(descriptor.filename))
    let receiptURL = modelRoot.appendingPathComponent("state.json")
    func receipt(enabled: Bool) throws -> Data {
        let value: [String: Any] = ["embedding": [
            "revision": descriptor.revision, "sha256": descriptor.sha256,
            "state": "downloaded", "enabled": enabled
        ]]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: receiptURL, options: .atomic)
        return data
    }
    let enabledReceipt = try receipt(enabled: true)
    let database = root.appendingPathComponent("history.sqlite")
    let store = try makeTestHistoryStore(url: database)
    func insert(_ text: String, source: String, concealed: Bool = false) throws -> Int64 {
        try store.insert(payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text",
            data: Data(text.utf8))]]), kind: .text, title: text, text: text, source: source,
            isConcealed: concealed, date: Date(), maxCount: 100, maxBytes: 1_000_000)
    }
    let code = try insert(#"raise ConnectionError("connection refused to PostgreSQL database")"#,
                          source: "Terminal")
    let exact = try insert("Ошибка подключения к базе: сервер PostgreSQL недоступен.", source: "Editor")
    let english = try insert("Database connection failed: PostgreSQL server refused the connection.",
                             source: "Editor")
    let unrelated = try insert("The weather is sunny and a dog is playing in the park.", source: "Safari")
    let concealed = try insert("Ошибка подключения к базе: synthetic concealed text.",
                               source: "Terminal", concealed: true)
    let bundle = URL(fileURLWithPath: arguments[2])
    let indexer = EmbeddingIndexer(databaseURL: database, modelRootURL: modelRoot, bundleURL: bundle,
                                  onProgress: { _ in }, onIndexed: {})
    let service = HybridSearchService(modelRootURL: modelRoot, bundleURL: bundle)
    defer {
        indexer.shutdown()
        service.shutdown()
    }
    await indexer.setEnabled(true)
    let deadline = Date().addingTimeInterval(60)
    while try store.embeddingProgress().complete < 4 {
        let progress = try store.embeddingProgress()
        try require(progress.failed == 0, "Production inference must not fail synthetic records")
        try require(Date() < deadline, "Production indexer must finish the isolated corpus")
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let progress = try store.embeddingProgress()
    try require(progress.complete == 4 && progress.total == 4 && progress.pending == 0,
                "Production indexer excludes concealed records and persists all normal vectors")
    try require(try store.embeddingIndexIdentity()?.fingerprint == EmbeddingConfiguration.fingerprint,
                "Production indexer persists the runtime pipeline identity")
    var filter = SearchFilter()
    filter.query = "ошибка подключения к базе"
    filter.excludesConcealed = true
    let result = try await service.search(databaseURL: database, filter: filter)
    try require(result.mode == .hybrid && result.fallbackReason == nil,
                "Production search uses actual indexed vectors")
    try require(result.rows.first?.id == exact, "Literal Russian phrase ranks before semantic results")
    try require(result.rows.contains { $0.id == code }, "Russian query retrieves code without shared words")
    try require(result.rows.contains { $0.id == english }, "Russian query retrieves relevant English text")
    try require(!result.rows.contains { $0.id == unrelated || $0.id == concealed },
                "Semantic threshold and conceal exclusion remove irrelevant records")
    filter.source = "Terminal"
    let sourceFiltered = try await service.search(databaseURL: database, filter: filter)
    try require(sourceFiltered.mode == .hybrid && sourceFiltered.rows.map(\.id) == [code],
                "Source filter also applies to semantic candidates")
    filter.source = nil
    filter.from = Date().addingTimeInterval(3600)
    let dateFiltered = try await service.search(databaseURL: database, filter: filter)
    try require(dateFiltered.rows.isEmpty, "Date filter also applies to semantic candidates")
    filter.from = nil
    let literal = try await service.search(databaseURL: database, filter: filter, mode: .literal)
    try require(literal.mode == .literal && literal.rows.map(\.id) == [exact],
                "Explicit literal mode does not add semantic matches")
    let currentReceipt = try Data(contentsOf: receiptURL)
    try require(currentReceipt == enabledReceipt, "Indexer and search never rewrite model preferences")
    let disabledReceipt = try receipt(enabled: false)
    let disabled = try await service.search(databaseURL: database, filter: filter)
    try require(disabled.mode == .literal && disabled.rows.map(\.id) == [exact] &&
                disabled.fallbackReason != nil, "External model disable falls back to literal search")
    try require(try Data(contentsOf: receiptURL) == disabledReceipt,
                "Fallback preserves the disabled model preference")
    try require(try store.embeddingProgress().complete == 4,
                "Disable retains completed embeddings for later resume")
    indexer.shutdown()
    service.shutdown()
    print("PASS: installed bundle production indexer → Metal worker → SQLite vectors → hybrid search")
    print("PASS: RU/EN/code retrieval, exact-first order, source/date filters, concealed exclusion")
    print("PASS: literal mode, external disable fallback, unchanged model receipts, retained index, shutdown")
}
