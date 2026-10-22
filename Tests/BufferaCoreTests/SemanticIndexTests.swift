import Foundation
import BufferaCore
import CSQLite

private final class SemanticFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var store: HistoryStore!
    let identity = EmbeddingIndexIdentity(fingerprint: "fixture-model-revision-prompt-chunks-v1", dimensions: 2)
    var url: URL { directory.appendingPathComponent("history.sqlite") }
    init() throws { store = try makeTestHistoryStore(url: url) }
    deinit { store = nil; try? FileManager.default.removeItem(at: directory) }
    @discardableResult func insert(_ text: String, kind: ClipKind = .text, source: String = "Fixture",
                                  concealed: Bool = false, remote: Bool = false, time: Double = 100,
                                  maxCount: Int = 50_000) throws -> Int64 {
        try store.insert(payload: ClipPayload(items: [[Representation(type: kind == .image ? "public.png" : "public.utf8-plain-text",
                                                                       data: Data(text.utf8))]]),
                         kind: kind, title: text, text: kind == .image ? "" : text, source: source,
                         isConcealed: concealed, isRemote: remote, date: Date(timeIntervalSince1970: time), maxCount: maxCount)
    }
    func configure() throws { try store.configureEmbeddingIndex(identity) }
    func finish(_ expectedID: Int64, _ vectors: [[Float]] = [[1, 0]], truncated: Bool = false) throws {
        let job = try store.nextPendingEmbedding()!
        try checkEqual(job.clipID, expectedID)
        try check(try store.completeEmbedding(job, vectors: vectors, isTruncated: truncated))
    }
    func query(_ text: String = "database connection", filter: SearchFilter = SearchFilter(),
               limit: Int = 150, offset: Int = 0, cached: [Int64]? = nil) throws -> HybridSearchPage {
        var filter = filter; filter.query = text
        return try store.hybridSearch(filter, vector: [1, 0], identity: identity, limit: limit, offset: offset, semanticIDs: cached)
    }
    func raw(_ sql: String) throws {
        var db: OpaquePointer?
        try checkEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try checkEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    func scalar(_ sql: String) throws -> Int {
        var db: OpaquePointer?, statement: OpaquePointer?
        try checkEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        try checkEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        try checkEqual(sqlite3_step(statement), SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
}

func runSemanticIndexChecks() -> Int {
    let checks: [(String, (SemanticFixture) throws -> Void)] = [
        ("Embedding queue persists, ignores ineligible content and rebuilds for a changed model", { fixture in
            let first = try fixture.insert("First text", time: 1)
            let second = try fixture.insert("Second text", kind: .link, time: 2)
            try fixture.insert(" \n\t", time: 3)
            try fixture.insert("hidden text", concealed: true, time: 4)
            try fixture.insert("opaque data", kind: .other, time: 5)
            try fixture.insert("image without OCR", kind: .image, time: 6)
            try fixture.configure()
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(pending: 3))
            try checkEqual(try fixture.scalar("SELECT COUNT(*) FROM clip_embedding_jobs WHERE content_fingerprint=''"), 3)
            try fixture.finish(second, truncated: true)
            let failed = try fixture.store.nextPendingEmbedding()!
            try check(try fixture.store.failEmbedding(failed))
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(complete: 1, failed: 1, truncated: 1))
            try checkEqual(try fixture.scalar("SELECT COUNT(*) FROM clip_embedding_jobs WHERE content_fingerprint=''"), 0)
            fixture.store = nil; fixture.store = try makeTestHistoryStore(url: fixture.url)
            try fixture.configure()
            try checkEqual(try fixture.store.nextPendingEmbedding()?.clipID, nil)
            try fixture.store.retryFailedEmbeddings(); try fixture.finish(first)
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(complete: 2, truncated: 1))
            try fixture.raw("UPDATE embedding_index SET input_version='old-input-policy'")
            try checkEqual(try fixture.store.embeddingIndexIdentity(), nil)
            try fixture.configure()
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(pending: 3))
            let next = EmbeddingIndexIdentity(fingerprint: "model-v2", dimensions: 2)
            try fixture.store.configureEmbeddingIndex(next)
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(pending: 3))
            try checkEqual(try fixture.scalar("SELECT COUNT(*) FROM clip_embedding_chunks"), 0)
            try check(!fixture.store.completeEmbedding(failed, vectors: [[1, 0]]))
        }),
        ("Hide, delete and pruning erase vectors and reject late workers", { fixture in
            try fixture.configure()
            let hidden = try fixture.insert("hidden after scheduling")
            let late = try fixture.store.nextPendingEmbedding()!
            try fixture.store.conceal(id: hidden)
            try check(!fixture.store.completeEmbedding(late, vectors: [[1, 0]]))
            try check(!fixture.store.failEmbedding(late))
            let complete = try fixture.insert("hidden after complete")
            try fixture.finish(complete, [[1, 0], [0, 1]])
            try fixture.store.conceal(id: complete)
            try checkEqual(try fixture.scalar("SELECT COUNT(*) FROM clip_embedding_chunks"), 0)
            let deleted = try fixture.insert("deleted while pending")
            let deletedJob = try fixture.store.nextPendingEmbedding()!
            try fixture.store.delete(id: deleted)
            try check(!fixture.store.completeEmbedding(deletedJob, vectors: [[1, 0]]))
            let favorite = try fixture.insert("favorite", time: 1)
            try fixture.store.setFavorite(id: favorite, isFavorite: true)
            try fixture.finish(favorite)
            let old = try fixture.insert("old indexed", time: 2)
            try fixture.finish(old)
            try fixture.insert("newest", time: 200, maxCount: 1)
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(pending: 1, complete: 1))
            try checkEqual(try fixture.scalar("SELECT COUNT(*) FROM clip_embedding_chunks"), 1)
        }),
        ("Repeated capture preserves vectors while OCR completion queues visible text", { fixture in
            try fixture.configure()
            let id = try fixture.insert("recopied text", source: "Old", time: 1)
            try fixture.finish(id)
            try checkEqual(try fixture.insert("recopied text", source: "New", remote: true, time: 2), id)
            try fixture.store.markUsed(id: id)
            try fixture.store.setFavorite(id: id, isFavorite: true)
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(complete: 1))
            let image = try fixture.insert("image pixels", kind: .image)
            try check(try fixture.store.completeImageText(id: image, text: "recognized invoice text"))
            try checkEqual(try fixture.store.nextPendingEmbedding()?.text, "recognized invoice text")
            try fixture.finish(image)
            let empty = try fixture.insert("empty image pixels", kind: .image)
            try fixture.store.completeImageText(id: empty, text: " \n ")
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(complete: 2))
            try checkEqual(try fixture.insert("recopied text", concealed: true), id)
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(complete: 1))
        }),
        ("Embedding validation rejects malformed vectors without completing a job", { fixture in
            try fixture.configure(); try fixture.insert("vector validation")
            let job = try fixture.store.nextPendingEmbedding()!
            for vectors: [[Float]] in [[], [[1]], [[0, 0]], [[.nan, 1]], [[.infinity, 1]], Array(repeating: [1, 0], count: 33)] {
                try checkThrows(try fixture.store.completeEmbedding(job, vectors: vectors))
            }
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(pending: 1))
            try check(try fixture.store.completeEmbedding(job, vectors: [[1, 0]]))
            try check(!fixture.store.completeEmbedding(job, vectors: [[1, 0]]))
        }),
        ("Hybrid ranking preserves exact results and collapses relevant chunks", { fixture in
            let exact = try fixture.insert("database connection exact", time: 1)
            try fixture.configure(); try fixture.finish(exact, [[0, 1]])
            let semantic = try fixture.insert("SQL connection refused", time: 2)
            try fixture.finish(semantic, [[0, 1], [1, 0]])
            let duplicateExact = try fixture.insert("database connection newer", time: 3)
            try fixture.finish(duplicateExact, [[1, 0]])
            let unrelated = try fixture.insert("cake ingredients", time: 4)
            try fixture.finish(unrelated, [[0, 1]])
            let page = try fixture.query()
            try checkEqual(page.rows.map(\.id), [duplicateExact, exact, semantic])
            try checkEqual(page.total, 3); try checkEqual(page.semanticCount, 1); try check(page.modelMatched)
            let secondPage = try fixture.query(limit: 1, offset: 2, cached: page.semanticIDs)
            try checkEqual(secondPage.rows.map(\.id), [semantic])
            var empty = SearchFilter(); empty.query = ""
            try checkEqual(try fixture.store.hybridSearch(empty, vector: [], identity: fixture.identity).rows.map(\.id),
                           try fixture.store.search(empty).map(\.id))
            let mismatched = try fixture.store.hybridSearch(SearchFilter(), vector: [], identity: .init(fingerprint: "other", dimensions: 2))
            try check(!mismatched.modelMatched)
        }),
        ("Hybrid applies every filter before its semantic candidate limit", { fixture in
            try fixture.configure()
            let wanted = try fixture.insert("wanted equivalent", source: "Safari", remote: true, time: 100)
            try fixture.finish(wanted)
            try fixture.store.setFavorite(id: wanted, isFavorite: true)
            for i in 0..<3 {
                let id = try fixture.insert("wrong app \(i)", source: "Notes", remote: true, time: 110 + Double(i))
                try fixture.finish(id)
                try fixture.store.setFavorite(id: id, isFavorite: true)
            }
            var filter = SearchFilter(); filter.query = "missing literal phrase"; filter.kind = .text
            filter.source = "Safari"; filter.favoritesOnly = true; filter.remoteOnly = true
            filter.from = Date(timeIntervalSince1970: 100); filter.until = Date(timeIntervalSince1970: 101)
            let page = try fixture.store.hybridSearch(filter, vector: [1, 0], identity: fixture.identity, semanticLimit: 1)
            try checkEqual(page.rows.map(\.id), [wanted]); try checkEqual(page.total, 1)
            filter.concealedOnly = true
            try checkEqual(try fixture.store.hybridSearch(filter, vector: [1, 0], identity: fixture.identity).total, 0)
            filter.concealedOnly = false; filter.until = Date(timeIntervalSince1970: 100)
            try checkEqual(try fixture.store.hybridSearch(filter, vector: [1, 0], identity: fixture.identity).total, 0)
        }),
        ("Cached semantic pages remain stable and revalidate concealed and filtered records", { fixture in
            try fixture.configure()
            let first = try fixture.insert("first semantic", time: 1); try fixture.finish(first)
            let second = try fixture.insert("second semantic", time: 2); try fixture.finish(second)
            let firstPage = try fixture.query(limit: 1)
            try checkEqual(firstPage.rows.map(\.id), [second])
            let newer = try fixture.insert("third semantic", time: 3); try fixture.finish(newer)
            let nextPage = try fixture.query(limit: 1, offset: 1, cached: firstPage.semanticIDs)
            try checkEqual(nextPage.rows.map(\.id), [first]); try checkEqual(nextPage.total, 2)
            try fixture.store.conceal(id: first)
            try checkEqual(try fixture.query(cached: firstPage.semanticIDs).rows.map(\.id), [second])
            var filter = SearchFilter(); filter.source = "Other"
            try checkEqual(try fixture.query(filter: filter, cached: firstPage.semanticIDs).total, 0)
        }),
        ("UTF-8 input limits are safe, reported and survive reopening", { fixture in
            try fixture.configure()
            let text = String(repeating: "🙂", count: 40_000)
            try fixture.insert(text)
            let job = try fixture.store.nextPendingEmbedding()!
            try check(job.isTruncated); try check(job.text.utf8.count <= 128 * 1024)
            try check(!job.text.contains("\u{FFFD}"))
            try check(try fixture.store.completeEmbedding(job, vectors: [[1, 0]]))
            fixture.store = nil; fixture.store = try makeTestHistoryStore(url: fixture.url)
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress(complete: 1, truncated: 1))
            try fixture.store.clearEmbeddings()
            try checkEqual(try fixture.store.embeddingProgress(), EmbeddingProgress())
            try checkEqual(try fixture.store.count(), 1)
            try check(!fixture.store.completeEmbedding(job, vectors: [[1, 0]]))
        }),
        ("Version six migration preserves records and begins without an enabled index", { fixture in
            let id = try fixture.insert("migration fixture")
            fixture.store = nil
            try fixture.raw("""
                DROP TABLE clip_embedding_chunks;
                DROP TABLE clip_embedding_jobs;
                DROP TABLE embedding_index;
                DROP TABLE secret_storage;
                DROP TABLE secret_maintenance;
                ALTER TABLE payloads DROP COLUMN encoding;
                PRAGMA user_version=6;
                """)
            try checkThrows(try makeTestHistoryStore(url: fixture.url, mode: .readOnly))
            fixture.store = try makeTestHistoryStore(url: fixture.url)
            try checkEqual(try fixture.scalar("PRAGMA user_version"), 9)
            try checkEqual(try fixture.store.summary(id: id).text, "migration fixture")
            try checkEqual(try fixture.store.embeddingIndexIdentity(), nil)
            try fixture.configure()
            try checkEqual(try fixture.store.nextPendingEmbedding()?.clipID, id)
            let reader = try makeTestHistoryStore(url: fixture.url, mode: .readOnly)
            try checkThrows(try reader.configureEmbeddingIndex(.init(fingerprint: "different", dimensions: 2)))
            try checkEqual(try reader.embeddingProgress().pending, 1)
        })
    ]
    var failures = 0
    for (name, run) in checks {
        do { try run(SemanticFixture()); print("PASS: \(name)") }
        catch { failures += 1; fputs("FAIL: \(name): \(error)\n", stderr) }
    }
    print("\(checks.count - failures)/\(checks.count) semantic index checks passed")
    return failures
}
