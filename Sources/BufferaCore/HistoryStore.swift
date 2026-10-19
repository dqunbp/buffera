import Foundation
import CSQLite

/// Confined to one serial queue by the application. No AppKit objects cross this boundary.
public final class HistoryStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let concealedTitle = "Скрытая запись"
    private static func concealedSearch(source: String) -> String {
        SearchFilter.normalize(concealedTitle + " " + source)
    }

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
            try migrate()
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let version = try schemaVersion()
            guard version <= 4 else { throw HistoryError.database("Версия истории новее, чем поддерживает это приложение.") }
            if version < 2 {
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
                ALTER TABLE clips ADD COLUMN is_concealed INTEGER NOT NULL DEFAULT 0;
                """)
            }
            if version < 3 {
                try execute("""
                ALTER TABLE clips ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;
                """)
            }
            if version < 4 {
                try execute("""
                CREATE TABLE clip_ocr (
                    clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
                    status TEXT NOT NULL CHECK(status IN ('pending','complete','failed')),
                    text TEXT NOT NULL DEFAULT '', search TEXT NOT NULL DEFAULT ''
                );
                CREATE INDEX clip_ocr_pending ON clip_ocr(clip_id) WHERE status='pending';
                INSERT INTO clip_ocr(clip_id,status)
                    SELECT id,'pending' FROM clips WHERE kind='image' AND is_concealed=0;
                PRAGMA user_version=4;
                """)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func schemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }

    @discardableResult
    public func insert(payload: ClipPayload, kind: ClipKind, title: String, text: String,
                       source: String, isConcealed: Bool = false, date: Date = Date(), maxCount: Int = 50_000,
                       maxBytes: Int = 5_000_000_000) throws -> Int64 {
        guard !payload.items.isEmpty, payload.items.allSatisfy({ !$0.isEmpty }) else { throw HistoryError.invalidPayload }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let encoded = try encoder.encode(payload)
        let storedTitle = isConcealed ? Self.concealedTitle : title
        let storedText = isConcealed ? "" : text
        let concealedSearch = Self.concealedSearch(source: source)
        let storedSearch = isConcealed ? concealedSearch : SearchFilter.normalize(title + " " + text + " " + source)
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT INTO clips(fingerprint,date,kind,title,text,source,search,bytes,is_concealed) VALUES(?,?,?,?,?,?,?,?,?)
                ON CONFLICT(fingerprint) DO UPDATE SET date=excluded.date, source=excluded.source,
                    is_concealed=MAX(clips.is_concealed,excluded.is_concealed),
                    title=CASE WHEN clips.is_concealed OR excluded.is_concealed THEN ? ELSE clips.title END,
                    text=CASE WHEN clips.is_concealed OR excluded.is_concealed THEN '' ELSE clips.text END,
                    search=CASE WHEN clips.is_concealed OR excluded.is_concealed THEN ? ELSE excluded.search END
                RETURNING id
                """)
            defer { sqlite3_finalize(statement) }
            try bind([.text(payload.fingerprint), .number(date.timeIntervalSince1970), .text(kind.rawValue),
                      .text(storedTitle), .text(storedText), .text(source), .text(storedSearch),
                      .integer(Int64(encoded.count)), .integer(isConcealed ? 1 : 0),
                      .text(Self.concealedTitle), .text(concealedSearch)], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            let id = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            let blob = try prepare("INSERT OR IGNORE INTO payloads(clip_id,data) VALUES(?,?)")
            defer { sqlite3_finalize(blob) }
            try bind([.integer(id), .blob(encoded)], to: blob)
            guard sqlite3_step(blob) == SQLITE_DONE else { throw failure() }
            try syncImageTextJob(id: id)
            try prune(maxCount: maxCount, maxBytes: maxBytes)
            try execute("COMMIT")
            return id
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func search(_ filter: SearchFilter, limit: Int = 150, offset: Int = 0) throws -> [ClipSummary] {
        let (clause, bindings) = predicate(filter)
        let statement = try prepare("SELECT id,date,kind,title,text,source,bytes,is_concealed,is_favorite FROM clips \(clause) ORDER BY date DESC,id DESC LIMIT ? OFFSET ?")
        defer { sqlite3_finalize(statement) }
        try bind(bindings + [.integer(Int64(limit)), .integer(Int64(offset))], to: statement)
        var result: [ClipSummary] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(ClipSummary(id: sqlite3_column_int64(statement, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: ClipKind(rawValue: string(statement, 2)) ?? .other, title: string(statement, 3),
                text: string(statement, 4), source: string(statement, 5), byteCount: Int(sqlite3_column_int64(statement, 6)),
                isConcealed: sqlite3_column_int(statement, 7) != 0,
                isFavorite: sqlite3_column_int(statement, 8) != 0))
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

    public func sources() throws -> [String] {
        let statement = try prepare("SELECT DISTINCT source FROM clips WHERE source<>''")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(string(statement, 0))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result.sorted {
            let order = $0.caseInsensitiveCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
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

    /// Setting the same value again is safe. Removing a favorite does not immediately prune history.
    public func setFavorite(id: Int64, isFavorite: Bool) throws {
        let statement = try prepare("UPDATE clips SET is_favorite=? WHERE id=? RETURNING id")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(isFavorite ? 1 : 0), .integer(id)], to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw HistoryError.missing }
        guard status == SQLITE_ROW else { throw failure() }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    public func conceal(id: Int64) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let source: String
            do {
                let statement = try prepare("SELECT source FROM clips WHERE id=?")
                defer { sqlite3_finalize(statement) }
                try bind([.integer(id)], to: statement)
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { throw HistoryError.missing }
                guard status == SQLITE_ROW else { throw failure() }
                source = string(statement, 0)
            }
            let statement = try prepare("UPDATE clips SET is_concealed=1,title=?,text='',search=? WHERE id=?")
            defer { sqlite3_finalize(statement) }
            try bind([.text(Self.concealedTitle), .text(Self.concealedSearch(source: source)), .integer(id)], to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try deleteImageText(id: id)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func nextPendingImageTextID() throws -> Int64? {
        let statement = try prepare("""
            SELECT clips.id FROM clip_ocr JOIN clips ON clips.id=clip_ocr.clip_id
            WHERE clip_ocr.status='pending' AND clips.kind='image' AND clips.is_concealed=0
            ORDER BY clips.date DESC,clips.id DESC LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }

    /// Obsolete results cannot restore a deleted, concealed, or already-finished job.
    @discardableResult
    public func completeImageText(id: Int64, text: String) throws -> Bool {
        let bounded = String(text.prefix(200_000))
        return try finishImageText(id: id, status: "complete", text: bounded,
                                   search: String(SearchFilter.normalize(bounded).prefix(200_000)))
    }

    @discardableResult
    public func failImageText(id: Int64) throws -> Bool {
        try finishImageText(id: id, status: "failed", text: "", search: "")
    }

    public func retryFailedImageText() throws {
        try execute("""
            UPDATE clip_ocr SET status='pending',text='',search=''
            WHERE status='failed' AND EXISTS (
                SELECT 1 FROM clips WHERE clips.id=clip_ocr.clip_id AND clips.kind='image' AND clips.is_concealed=0
            )
            """)
    }

    public func imageTextProgress() throws -> ImageTextProgress {
        let statement = try prepare("SELECT status,COUNT(*) FROM clip_ocr GROUP BY status")
        defer { sqlite3_finalize(statement) }
        var pending = 0, complete = 0, failed = 0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let count = Int(sqlite3_column_int64(statement, 1))
            switch string(statement, 0) {
            case "pending": pending = count
            case "complete": complete = count
            case "failed": failed = count
            default: throw HistoryError.database("Неизвестное состояние распознавания текста.")
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return ImageTextProgress(pending: pending, complete: complete, failed: failed)
    }

    private func finishImageText(id: Int64, status: String, text: String, search: String) throws -> Bool {
        let statement = try prepare("""
            UPDATE clip_ocr SET status=?,text=?,search=?
            WHERE clip_id=? AND status='pending' AND EXISTS (
                SELECT 1 FROM clips WHERE clips.id=clip_ocr.clip_id AND clips.kind='image' AND clips.is_concealed=0
            ) RETURNING clip_id
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.text(status), .text(text), .text(search), .integer(id)], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return false }
        guard result == SQLITE_ROW else { throw failure() }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return true
    }

    private func syncImageTextJob(id: Int64) throws {
        let cleanup = try prepare("""
            DELETE FROM clip_ocr WHERE clip_id=? AND NOT EXISTS (
                SELECT 1 FROM clips WHERE clips.id=clip_ocr.clip_id AND clips.kind='image' AND clips.is_concealed=0
            )
            """)
        defer { sqlite3_finalize(cleanup) }
        try bind([.integer(id)], to: cleanup)
        guard sqlite3_step(cleanup) == SQLITE_DONE else { throw failure() }
        let enqueue = try prepare("""
            INSERT OR IGNORE INTO clip_ocr(clip_id,status)
            SELECT id,'pending' FROM clips WHERE id=? AND kind='image' AND is_concealed=0
            """)
        defer { sqlite3_finalize(enqueue) }
        try bind([.integer(id)], to: enqueue)
        guard sqlite3_step(enqueue) == SQLITE_DONE else { throw failure() }
    }

    private func deleteImageText(id: Int64) throws {
        let statement = try prepare("DELETE FROM clip_ocr WHERE clip_id=?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func prune(maxCount: Int, maxBytes: Int) throws {
        // Favorites are outside the automatic limits. Keep the newest ordinary prefix within both limits.
        let statement = try prepare("""
            DELETE FROM clips WHERE id IN (
                SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (ORDER BY date DESC,id DESC) AS position,
                    SUM(bytes) OVER (ORDER BY date DESC,id DESC) AS total FROM clips WHERE is_favorite=0
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
            clauses.append("""
                (clips.search LIKE ? ESCAPE '\\' OR (clips.is_concealed=0 AND EXISTS (
                    SELECT 1 FROM clip_ocr WHERE clip_ocr.clip_id=clips.id AND clip_ocr.status='complete'
                        AND clip_ocr.search LIKE ? ESCAPE '\\'
                )))
                """)
            bindings += [.text("%\(escaped)%"), .text("%\(escaped)%")]
        }
        if let kind = filter.kind { clauses.append("kind=?"); bindings.append(.text(kind.rawValue)) }
        if let source = filter.source { clauses.append("source=?"); bindings.append(.text(source)) }
        if filter.favoritesOnly { clauses.append("is_favorite=1") }
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
