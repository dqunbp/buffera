import Foundation
import CSQLite

/// Confined to one serial queue by the application. No AppKit objects cross this boundary.
public final class HistoryStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("""
                CREATE TABLE IF NOT EXISTS clips (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, fingerprint TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
                    text TEXT NOT NULL, source TEXT NOT NULL, search TEXT NOT NULL,
                    bytes INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS payloads (
                    clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
                    data BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS clips_date ON clips(date DESC, id DESC);
                PRAGMA user_version=1;
                """)
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    public func insert(payload: ClipPayload, kind: ClipKind, title: String, text: String,
                       source: String, date: Date = Date(), maxCount: Int = 50_000,
                       maxBytes: Int = 5_000_000_000) throws -> Int64 {
        guard !payload.items.isEmpty, payload.items.allSatisfy({ !$0.isEmpty }) else { throw HistoryError.invalidPayload }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let encoded = try encoder.encode(payload)
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT INTO clips(fingerprint,date,kind,title,text,source,search,bytes) VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(fingerprint) DO UPDATE SET date=excluded.date, source=excluded.source, search=excluded.search
                RETURNING id
                """)
            defer { sqlite3_finalize(statement) }
            try bind([.text(payload.fingerprint), .number(date.timeIntervalSince1970), .text(kind.rawValue),
                      .text(title), .text(text), .text(source), .text(SearchFilter.normalize(title + " " + text + " " + source)),
                      .integer(Int64(encoded.count))], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            let id = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            let blob = try prepare("INSERT OR IGNORE INTO payloads(clip_id,data) VALUES(?,?)")
            defer { sqlite3_finalize(blob) }
            try bind([.integer(id), .blob(encoded)], to: blob)
            guard sqlite3_step(blob) == SQLITE_DONE else { throw failure() }
            try prune(maxCount: maxCount, maxBytes: maxBytes)
            try execute("COMMIT")
            return id
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func search(_ filter: SearchFilter, limit: Int = 150, offset: Int = 0) throws -> [ClipSummary] {
        let (clause, bindings) = predicate(filter)
        let statement = try prepare("SELECT id,date,kind,title,text,source,bytes FROM clips \(clause) ORDER BY date DESC,id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(statement) }
        try bind(bindings + [.integer(Int64(limit)), .integer(Int64(offset))], to: statement)
        var result: [ClipSummary] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(ClipSummary(id: sqlite3_column_int64(statement, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: ClipKind(rawValue: string(statement, 2)) ?? .other, title: string(statement, 3),
                text: string(statement, 4), source: string(statement, 5), byteCount: Int(sqlite3_column_int64(statement, 6))))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    public func count(_ filter: SearchFilter = SearchFilter()) throws -> Int {
        let (clause, bindings) = predicate(filter)
        let statement = try prepare("SELECT COUNT(*) FROM clips \(clause)")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func payload(id: Int64) throws -> ClipPayload {
        let statement = try prepare("SELECT data FROM payloads WHERE clip_id=?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw HistoryError.missing }
        guard let bytes = sqlite3_column_blob(statement, 0) else { throw HistoryError.invalidPayload }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try PropertyListDecoder().decode(ClipPayload.self, from: data)
    }

    public func delete(id: Int64) throws {
        let statement = try prepare("DELETE FROM clips WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func prune(maxCount: Int, maxBytes: Int) throws {
        // Window sum keeps the newest prefix within both configured limits.
        let statement = try prepare("""
            DELETE FROM clips WHERE id IN (
                SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (ORDER BY date DESC,id DESC) AS position,
                    SUM(bytes) OVER (ORDER BY date DESC,id DESC) AS total FROM clips
                ) WHERE position > ? OR total > ?
            )
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.integer(Int64(max(1, maxCount))), .integer(Int64(max(1, maxBytes)))], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private enum Value { case text(String), number(Double), integer(Int64), blob(Data) }
    private func predicate(_ filter: SearchFilter) -> (String, [Value]) {
        var clauses: [String] = []; var bindings: [Value] = []
        for token in SearchFilter.normalize(filter.query).split(whereSeparator: { $0.isWhitespace }) {
            let escaped = token.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            clauses.append("search LIKE ? ESCAPE '\\'"); bindings.append(.text("%\(escaped)%"))
        }
        if let kind = filter.kind { clauses.append("kind=?"); bindings.append(.text(kind.rawValue)) }
        if let from = filter.from { clauses.append("date>=?"); bindings.append(.number(from.timeIntervalSince1970)) }
        if let until = filter.until { clauses.append("date<?"); bindings.append(.number(until.timeIntervalSince1970)) }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), bindings)
    }

    private func failure() -> HistoryError { .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "не удалось открыть файл") }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let value): status = sqlite3_bind_text(statement, index, value, -1, transient)
            case .number(let value): status = sqlite3_bind_double(statement, index, value)
            case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
            case .blob(let value): status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard status == SQLITE_OK else { throw failure() }
        }
    }
    private func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}
