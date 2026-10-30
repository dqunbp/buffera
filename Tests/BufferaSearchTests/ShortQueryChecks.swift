import Foundation
import BufferaCore
import BufferaSearch

private actor QueryRecorder {
    private(set) var queries: [String] = []
    let identity: EmbeddingIndexIdentity

    init(identity: EmbeddingIndexIdentity) { self.identity = identity }

    func embed(_ query: String) -> SemanticQuery {
        queries.append(query)
        return SemanticQuery(vector: [1, 0], identity: identity)
    }
}

func checkShortQueries(root: URL) async throws {
    let database = root.appendingPathComponent("short-query-history.sqlite")
    let store = try makeTestHistoryStore(url: database)
    func insert(_ text: String, source: String = "Notes", time: Double,
                favorite: Bool = true) throws -> Int64 {
        let id = try store.insert(payload: ClipPayload(items: [[Representation(type: "public.utf8-plain-text",
            data: Data(text.utf8))]]), kind: .text, title: text, text: text, source: source,
            isConcealed: false, date: Date(timeIntervalSince1970: time), maxCount: 100, maxBytes: 1_000_000)
        try store.setFavorite(id: id, isFavorite: favorite)
        return id
    }
    let older = try insert("ab older", time: 1)
    let newer = try insert("ab newer", time: 2)
    _ = try insert("ab other source", source: "Browser", time: 3)
    _ = try insert("ab nonfavorite", time: 4, favorite: false)
    let semantic = try insert("meaning companion", time: 5)
    let identity = EmbeddingIndexIdentity(fingerprint: "short-query-fixture", dimensions: 2)
    try store.configureEmbeddingIndex(identity)
    while let job = try store.nextPendingEmbedding() {
        try require(try store.completeEmbedding(job, vectors: [job.clipID == semantic ? [1, 0] : [0, 1]]),
                    "Short-query fixture must complete its index")
    }
    let recorder = QueryRecorder(identity: identity)
    let service = HybridSearchService(queryProvider: { await recorder.embed($0) })

    // Unicode scalars and UTF-8 bytes must not promote a one/two-character query to inference.
    let shortQueries = ["", " \n\t", "a", "ab", "  ab \n", "e\u{301}", "e\u{301}a", "👨‍👩‍👧‍👦", "🇦🇲x"]
    for mode in [HistorySearchMode.automatic, .hybrid] {
        for query in shortQueries {
            var filter = SearchFilter(); filter.query = query
            try require(!mode.usesSemanticSearch(for: filter), "Short-query scheduling must bypass inference")
            let result = try await service.search(databaseURL: database, filter: filter, mode: mode)
            try require(result.mode == .literal && result.fallbackReason == nil,
                        "Short queries must use literal search without reporting a model failure")
            try require(result.rows.map(\.id) == store.search(filter).map(\.id) && result.total == store.count(filter),
                        "Short queries must preserve the canonical literal results and count")
        }
    }
    try require(await recorder.queries.isEmpty, "Zero, one and two characters must never call the query provider")

    var filter = SearchFilter(); filter.query = "  ab \n"
    filter.source = "Notes"; filter.favoritesOnly = true; filter.kind = .text
    let first = try await service.search(databaseURL: database, filter: filter, limit: 1)
    let second = try await service.search(databaseURL: database, filter: filter, limit: 1, offset: 1)
    try require(first.rows.map(\.id) == [newer] && second.rows.map(\.id) == [older] &&
                first.total == 2 && second.total == 2,
                "Short-query filtering, recent-use ordering and pagination must remain literal")
    try require(await recorder.queries.isEmpty, "Short-query pagination must not start inference")

    for (mode, query, expected) in [(HistorySearchMode.automatic, "abc", "abc"),
                                   (.hybrid, "  xyz \n", "xyz"), (.automatic, "e\u{301}ab", "e\u{301}ab"),
                                   (.automatic, "a b", "a b")] {
        filter.query = query
        try require(mode.usesSemanticSearch(for: filter), "Three characters must enable semantic search")
        let previousCalls = await recorder.queries.count
        let result = try await service.search(databaseURL: database, filter: filter, mode: mode)
        let queries = await recorder.queries
        try require(queries.count == previousCalls + 1 && queries.last == expected,
                    "Eligible automatic and hybrid queries must embed the trimmed query")
        try require(result.mode == .hybrid && result.rows.contains { $0.id == semantic },
                    "Three-character queries must include their semantic candidates")
    }

    let callsBeforeBypass = await recorder.queries.count
    filter.query = "abc"
    try require(!HistorySearchMode.literal.usesSemanticSearch(for: filter), "Literal mode must bypass inference")
    let literal = try await service.search(databaseURL: database, filter: filter, mode: .literal)
    filter.concealedOnly = true
    try require(!HistorySearchMode.automatic.usesSemanticSearch(for: filter), "Concealed-only search must bypass inference")
    let concealed = try await service.search(databaseURL: database, filter: filter)
    try require(literal.mode == .literal && concealed.mode == .literal &&
                literal.fallbackReason == nil && concealed.fallbackReason == nil &&
                literal.rows.isEmpty && concealed.rows.isEmpty,
                "Explicit literal and concealed-only searches must keep their literal result")
    try require(await recorder.queries.count == callsBeforeBypass, "Bypass modes must never call the query provider")

    filter.concealedOnly = false
    let long = try await service.search(databaseURL: database, filter: filter, limit: 1)
    filter.query = "ab"
    let short = try await service.search(databaseURL: database, filter: filter, limit: 1)
    let shortPage = try await service.search(databaseURL: database, filter: filter, limit: 1, offset: 1)
    filter.query = "abc"
    let longAgain = try await service.search(databaseURL: database, filter: filter, limit: 1)
    try require(long.rows.map(\.id) == [semantic] && longAgain.rows.map(\.id) == [semantic] &&
                short.rows.map(\.id) == [newer] && shortPage.rows.map(\.id) == [older] &&
                short.mode == .literal && shortPage.mode == .literal && short.total == 2 && shortPage.total == 2,
                "Long-short-long transitions must not leak cached semantic candidates into literal pages")
    try require(await recorder.queries.count == callsBeforeBypass + 2,
                "Only the two long requests may infer during a long-short-long transition")
    print("PASS: short-query inference bypass, Unicode length, filters, pagination and semantic transitions")
}
