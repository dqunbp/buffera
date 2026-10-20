import BufferaLocalization
import Foundation
import CryptoKit
import CSQLite

public struct EmbeddingIndexIdentity: Equatable, Sendable {
    public let fingerprint: String
    public let dimensions: Int
    public init(fingerprint: String, dimensions: Int = 768) {
        self.fingerprint = fingerprint; self.dimensions = dimensions
    }
}

public struct EmbeddingJob: Sendable {
    public let clipID: Int64
    public let modelFingerprint: String
    public let contentFingerprint: String
    public let text: String
    public let isTruncated: Bool
}

public struct EmbeddingProgress: Equatable, Sendable {
    public let pending: Int
    public let complete: Int
    public let failed: Int
    public let truncated: Int
    public var total: Int { pending + complete + failed }
    public init(pending: Int = 0, complete: Int = 0, failed: Int = 0, truncated: Int = 0) {
        self.pending = pending; self.complete = complete; self.failed = failed; self.truncated = truncated
    }
}

public struct HybridSearchPage: Sendable {
    public let rows: [ClipSummary]
    public let total: Int
    public let semanticCount: Int
    public let modelMatched: Bool
    public let semanticIDs: [Int64]
    public init(rows: [ClipSummary], total: Int, semanticCount: Int, modelMatched: Bool, semanticIDs: [Int64] = []) {
        self.rows = rows; self.total = total; self.semanticCount = semanticCount; self.modelMatched = modelMatched
        self.semanticIDs = semanticIDs
    }
}

extension HistoryStore {
    /// Versioned independently from the model so an input-policy change rebuilds derived data.
    private static let embeddingInputVersion = "utf8-131072-v1"
    private static let embeddingInputLimit = 128 * 1024

    public func embeddingIndexIdentity() throws -> EmbeddingIndexIdentity? {
        let statement = try prepare("SELECT fingerprint,dimensions,input_version FROM embedding_index WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        guard string(statement, 2) == Self.embeddingInputVersion else { return nil }
        return EmbeddingIndexIdentity(fingerprint: string(statement, 0), dimensions: Int(sqlite3_column_int(statement, 1)))
    }

    /// Creates a durable queue for existing history. Reusing the same model preserves completed work.
    public func configureEmbeddingIndex(_ identity: EmbeddingIndexIdentity) throws {
        guard !identity.fingerprint.isEmpty, (1...8192).contains(identity.dimensions) else {
            throw HistoryError.database(L10n.text("Некорректные параметры смыслового индекса."))
        }
        if try embeddingIndexIdentity() == identity { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM clip_embedding_jobs; DELETE FROM embedding_index")
            let statement = try prepare("INSERT INTO embedding_index(singleton,fingerprint,dimensions,input_version) VALUES(1,?,?,?)")
            defer { sqlite3_finalize(statement) }
            try bind([.text(identity.fingerprint), .integer(Int64(identity.dimensions)), .text(Self.embeddingInputVersion)], to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            // Queue IDs in SQL; hashing every document here would hold the history write lock
            // while scanning gigabytes of text. Inputs are prepared one at a time by the worker.
            try execute("""
                INSERT INTO clip_embedding_jobs(clip_id,content_fingerprint,status)
                SELECT clips.id,'','pending' FROM clips LEFT JOIN clip_ocr ON clip_ocr.clip_id=clips.id
                WHERE clips.is_concealed=0 AND (
                    clips.kind IN ('text','link','file') OR
                    (clips.kind='image' AND clip_ocr.status='complete')
                )
                """)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Stops exposing derived vectors immediately. Clipboard records and payloads are untouched.
    public func clearEmbeddings() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM clip_embedding_jobs; DELETE FROM embedding_index")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func nextPendingEmbedding() throws -> EmbeddingJob? {
        guard let identity = try embeddingIndexIdentity() else { return nil }
        while let record = try pendingEmbeddingRecord() {
            guard let input = try embeddingInput(id: record.id) else {
                try removeEmbeddingJob(id: record.id)
                continue
            }
            if !record.fingerprint.isEmpty, record.fingerprint != input.fingerprint {
                try syncEmbeddingJob(id: record.id)
                continue
            }
            if record.fingerprint.isEmpty {
                let prepareJob = try prepare("""
                    UPDATE clip_embedding_jobs SET content_fingerprint=?,input_truncated=?
                    WHERE clip_id=? AND status='pending' AND content_fingerprint=''
                    """)
                defer { sqlite3_finalize(prepareJob) }
                try bind([.text(input.fingerprint), .integer(input.truncated ? 1 : 0), .integer(record.id)], to: prepareJob)
                guard sqlite3_step(prepareJob) == SQLITE_DONE else { throw failure() }
                if sqlite3_changes(db) == 0 { continue }
            }
            return EmbeddingJob(clipID: record.id, modelFingerprint: identity.fingerprint,
                                contentFingerprint: input.fingerprint, text: input.text, isTruncated: input.truncated)
        }
        return nil
    }

    private func pendingEmbeddingRecord() throws -> (id: Int64, fingerprint: String)? {
        let statement = try prepare("""
            SELECT clips.id,clip_embedding_jobs.content_fingerprint
            FROM clip_embedding_jobs JOIN clips ON clips.id=clip_embedding_jobs.clip_id
            WHERE clip_embedding_jobs.status='pending' AND clips.is_concealed=0
            ORDER BY clips.date DESC,clips.id DESC LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return (sqlite3_column_int64(statement, 0), string(statement, 1))
    }

    /// A late worker cannot restore vectors for a hidden/deleted clip or another model/content version.
    @discardableResult
    public func completeEmbedding(_ job: EmbeddingJob, vectors: [[Float]], isTruncated: Bool = false) throws -> Bool {
        guard let identity = try embeddingIndexIdentity(), identity.fingerprint == job.modelFingerprint else { return false }
        guard !vectors.isEmpty, vectors.count <= 32 else {
            throw HistoryError.database(L10n.text("Модель вернула неверное число фрагментов текста."))
        }
        let encoded = try vectors.map { try embeddingData($0, dimensions: identity.dimensions) }
        try execute("BEGIN IMMEDIATE")
        do {
            guard try embeddingIndexIdentity() == identity, try embeddingJobMatches(job) else {
                try execute("COMMIT"); return false
            }
            let statement = try prepare("""
                INSERT INTO clip_embedding_chunks(clip_id,chunk_index,vector) VALUES(?,?,?)
                """)
            defer { sqlite3_finalize(statement) }
            for (index, vector) in encoded.enumerated() {
                try bind([.integer(job.clipID), .integer(Int64(index)), .blob(vector)], to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
            let finish = try prepare("UPDATE clip_embedding_jobs SET status='complete',index_truncated=? WHERE clip_id=?")
            defer { sqlite3_finalize(finish) }
            try bind([.integer(job.isTruncated || isTruncated ? 1 : 0), .integer(job.clipID)], to: finish)
            guard sqlite3_step(finish) == SQLITE_DONE else { throw failure() }
            try execute("COMMIT")
            return true
        } catch { try? execute("ROLLBACK"); throw error }
    }

    @discardableResult
    public func failEmbedding(_ job: EmbeddingJob) throws -> Bool {
        guard try embeddingIndexIdentity()?.fingerprint == job.modelFingerprint else { return false }
        let statement = try prepare("""
            UPDATE clip_embedding_jobs SET status='failed'
            WHERE clip_id=? AND content_fingerprint=? AND status='pending'
                AND EXISTS (SELECT 1 FROM clips WHERE clips.id=clip_id AND is_concealed=0)
                AND EXISTS (SELECT 1 FROM embedding_index WHERE fingerprint=? AND input_version=?)
            RETURNING clip_id
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.integer(job.clipID), .text(job.contentFingerprint),
                  .text(job.modelFingerprint), .text(Self.embeddingInputVersion)], to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return false }
        guard status == SQLITE_ROW, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return true
    }

    public func retryFailedEmbeddings() throws {
        try execute("UPDATE clip_embedding_jobs SET status='pending' WHERE status='failed'")
    }

    public func embeddingProgress() throws -> EmbeddingProgress {
        let statement = try prepare("""
            SELECT status,COUNT(*),SUM(index_truncated) FROM clip_embedding_jobs GROUP BY status
            """)
        defer { sqlite3_finalize(statement) }
        var pending = 0, complete = 0, failed = 0, truncated = 0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let count = Int(sqlite3_column_int64(statement, 1))
            switch string(statement, 0) {
            case "pending": pending = count
            case "complete": complete = count; truncated = Int(sqlite3_column_int64(statement, 2))
            case "failed": failed = count
            default: throw HistoryError.database(L10n.text("Неизвестное состояние смыслового индекса."))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return EmbeddingProgress(pending: pending, complete: complete, failed: failed, truncated: truncated)
    }

    /// Exact matches retain their original ordering. Additional semantic matches are filtered before
    /// ranking, collapsed across chunks, and never include concealed records.
    public func hybridSearch(_ filter: SearchFilter, vector: [Float], identity: EmbeddingIndexIdentity,
                             limit: Int = 150, offset: Int = 0, maximumDistance: Float = 0.30,
                             semanticLimit: Int = 200, semanticIDs cachedIDs: [Int64]? = nil) throws -> HybridSearchPage {
        try withReadSnapshot {
            let matched = try embeddingIndexIdentity() == identity
            guard matched, !filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return HybridSearchPage(rows: try search(filter, limit: limit, offset: offset),
                                        total: try count(filter), semanticCount: 0, modelMatched: matched)
            }
            guard maximumDistance.isFinite, (0...2).contains(maximumDistance) else {
                throw HistoryError.database(L10n.text("Некорректный порог смыслового поиска."))
            }
            let query = try embeddingData(vector, dimensions: identity.dimensions)
            let (exactClause, exactBindings) = predicate(filter)
            let exactIDs = try embeddingIDs("""
                SELECT clips.id FROM clips \(exactClause) ORDER BY sort_date DESC,id DESC
                """, bindings: exactBindings)
            var semanticFilter = filter
            semanticFilter.query = ""; semanticFilter.excludesConcealed = true
            let (clause, bindings) = predicate(semanticFilter)
            let semanticIDs: [Int64]
            if let cachedIDs {
                var seen = Set<Int64>()
                let bounded = Array(cachedIDs.filter { seen.insert($0).inserted }.prefix(1000))
                if bounded.isEmpty { semanticIDs = [] }
                else {
                    let placeholders = Array(repeating: "?", count: bounded.count).joined(separator: ",")
                    let valid = Set(try embeddingIDs("""
                        SELECT clips.id FROM clips JOIN clip_embedding_jobs ON clip_embedding_jobs.clip_id=clips.id
                        \(clause) AND clip_embedding_jobs.status='complete' AND clips.id IN (\(placeholders))
                        """, bindings: bindings + bounded.map(Value.integer)))
                    semanticIDs = bounded.filter { valid.contains($0) }
                }
            } else {
                semanticIDs = try embeddingIDs("""
                    SELECT clips.id,MIN(vec_distance_cosine(clip_embedding_chunks.vector,?)) AS distance
                    FROM clips JOIN clip_embedding_jobs ON clip_embedding_jobs.clip_id=clips.id
                    JOIN clip_embedding_chunks ON clip_embedding_chunks.clip_id=clips.id
                    \(clause) AND clip_embedding_jobs.status='complete'
                    GROUP BY clips.id HAVING distance<=?
                    ORDER BY distance ASC,clips.sort_date DESC,clips.id DESC LIMIT ?
                    """, bindings: [.blob(query)] + bindings +
                        [.number(Double(maximumDistance)), .integer(Int64(max(0, min(1000, semanticLimit))))])
            }
            let exactSet = Set(exactIDs)
            let additional = semanticIDs.filter { !exactSet.contains($0) }
            let allIDs = exactIDs + additional
            let selected = Array(allIDs.dropFirst(max(0, offset)).prefix(max(0, limit)))
            let rows: [ClipSummary]
            if selected.isEmpty { rows = [] }
            else {
                var byID: [Int64: ClipSummary] = [:]
                for start in stride(from: 0, to: selected.count, by: 500) {
                    let batch = Array(selected[start..<min(start + 500, selected.count)])
                    let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                    let results = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE id IN (\(placeholders))",
                                                bindings: batch.map(Value.integer))
                    for result in results { byID[result.id] = result }
                }
                rows = selected.compactMap { byID[$0] }
            }
            return HybridSearchPage(rows: rows, total: allIDs.count, semanticCount: additional.count,
                                    modelMatched: true, semanticIDs: semanticIDs)
        }
    }

    // Called inside the owning capture/OCR/conceal transaction. Source, dates and favorite flags
    // are filters rather than embedding inputs, so recopying the same text preserves completed work.
    func syncEmbeddingJob(id: Int64) throws {
        guard try embeddingIndexIdentity() != nil else { try removeEmbeddingJob(id: id); return }
        guard let input = try embeddingInput(id: id) else { try removeEmbeddingJob(id: id); return }
        let remove = try prepare("DELETE FROM clip_embedding_jobs WHERE clip_id=? AND content_fingerprint<>?")
        defer { sqlite3_finalize(remove) }
        try bind([.integer(id), .text(input.fingerprint)], to: remove)
        guard sqlite3_step(remove) == SQLITE_DONE else { throw failure() }
        let enqueue = try prepare("""
            INSERT OR IGNORE INTO clip_embedding_jobs(clip_id,content_fingerprint,status,input_truncated)
            VALUES(?,?,'pending',?)
            """)
        defer { sqlite3_finalize(enqueue) }
        try bind([.integer(id), .text(input.fingerprint), .integer(input.truncated ? 1 : 0)], to: enqueue)
        guard sqlite3_step(enqueue) == SQLITE_DONE else { throw failure() }
    }

    private func removeEmbeddingJob(id: Int64) throws {
        let statement = try prepare("DELETE FROM clip_embedding_jobs WHERE clip_id=?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func embeddingIDs(_ sql: String, bindings: [Value]) throws -> [Int64] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var ids: [Int64] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)); status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure() }
        return ids
    }

    private func embeddingInput(id: Int64) throws -> (text: String, fingerprint: String, truncated: Bool)? {
        let statement = try prepare("""
            SELECT CASE WHEN clips.kind='image' THEN clip_ocr.text ELSE clips.text END
            FROM clips LEFT JOIN clip_ocr ON clip_ocr.clip_id=clips.id
            WHERE clips.id=? AND clips.is_concealed=0 AND (
                clips.kind IN ('text','link','file') OR (clips.kind='image' AND clip_ocr.status='complete')
            )
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        let source = string(statement, 0).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let bytes = Array(source.utf8.prefix(Self.embeddingInputLimit + 1))
        let truncated = bytes.count > Self.embeddingInputLimit
        var bounded = Array(bytes.prefix(Self.embeddingInputLimit))
        // At most three suffix bytes need removal to end on a complete UTF-8 scalar.
        while String(bytes: bounded, encoding: .utf8) == nil { bounded.removeLast() }
        let text = String(decoding: bounded, as: UTF8.self)
        var hash = SHA256()
        hash.update(data: Data(Self.embeddingInputVersion.utf8)); hash.update(data: Data(bounded))
        hash.update(data: Data([truncated ? 1 : 0]))
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return (text, fingerprint, truncated)
    }

    private func embeddingJobMatches(_ job: EmbeddingJob) throws -> Bool {
        let statement = try prepare("""
            SELECT 1 FROM clip_embedding_jobs JOIN clips ON clips.id=clip_embedding_jobs.clip_id
            WHERE clip_id=? AND content_fingerprint=? AND status='pending' AND clips.is_concealed=0
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.integer(job.clipID), .text(job.contentFingerprint)], to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw failure() }
        return status == SQLITE_ROW
    }

    private func embeddingData(_ vector: [Float], dimensions: Int) throws -> Data {
        guard vector.count == dimensions, vector.allSatisfy(\.isFinite),
              vector.contains(where: { $0 != 0 }) else {
            throw HistoryError.database(L10n.text("Модель вернула некорректный вектор."))
        }
        // Normalize using Double to avoid Float accumulation overflow for otherwise finite inputs.
        let length = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        let values = vector.map { Float(Double($0) / length).bitPattern.littleEndian }
        return values.withUnsafeBytes { Data($0) }
    }
}
