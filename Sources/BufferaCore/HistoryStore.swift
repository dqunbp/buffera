import BufferaLocalization
import Foundation
import CSQLite
import CSQLiteVec

/// Confined to one serial queue by the application. No AppKit objects cross this boundary.
public final class HistoryStore {
    public enum OpenMode { case readWrite, readOnly }

    var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let schemaVersion = 9
    let secretCipher: SecretPayloadCipher?
    static let summaryColumns = "id,date,kind,title,text,source,bytes,is_concealed,is_favorite,is_remote"
    // Storage/search sentinel: presentation translates it through ClipSummary.displayTitle.
    public static let concealedTitle = "Скрытая запись"
    private static func concealedSearch(source: String) -> String {
        SearchFilter.normalize(concealedTitle + " " + source)
    }

    public init(url: URL, mode: OpenMode = .readWrite, secretCipher: SecretPayloadCipher? = nil) throws {
        self.secretCipher = secretCipher
        if mode == .readWrite {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let flags = mode == .readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let error: HistoryError = mode == .readOnly
                ? .database(L10n.text("Не удалось открыть историю для чтения. Сначала запустите Buffera и проверьте путь к истории."))
                : failure()
            sqlite3_close(db); db = nil; throw error
        }
        do {
            guard sqlite3_vec_init(db, nil, nil) == SQLITE_OK else { throw failure() }
            sqlite3_busy_timeout(db, 3000)
            if mode == .readOnly {
                let version = try schemaVersion()
                guard version == Self.schemaVersion else {
                    let recovery = version < Self.schemaVersion
                        ? L10n.text("Запустите Buffera, чтобы обновить историю.")
                        : L10n.text("Обновите Buffera и подключённый MCP.")
                    throw HistoryError.database(L10n.text("Неподдерживаемая версия истории \(version); требуется \(Self.schemaVersion). \(recovery)"))
                }
            } else {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA foreign_keys=ON")
                try execute("PRAGMA secure_delete=ON")
                try migrate()
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { sqlite3_close(db) }

    private func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let version = try schemaVersion()
            guard version <= Self.schemaVersion else { throw HistoryError.database(L10n.text("Версия истории новее, чем поддерживает это приложение.")) }
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
            if version < 5 {
                try execute("""
                ALTER TABLE clips ADD COLUMN is_remote INTEGER NOT NULL DEFAULT 0 CHECK(is_remote IN (0,1));
                PRAGMA user_version=5;
                """)
            }
            if version < 6 {
                try execute("""
                ALTER TABLE clips ADD COLUMN sort_date REAL NOT NULL DEFAULT 0;
                UPDATE clips SET sort_date=date;
                CREATE INDEX clips_sort_date ON clips(sort_date DESC,id DESC);
                PRAGMA user_version=6;
                """)
            }
            if version < 7 {
                try execute("""
                CREATE TABLE embedding_index (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    fingerprint TEXT NOT NULL, dimensions INTEGER NOT NULL CHECK(dimensions>0),
                    input_version TEXT NOT NULL
                );
                CREATE TABLE clip_embedding_jobs (
                    clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
                    content_fingerprint TEXT NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('pending','complete','failed')),
                    input_truncated INTEGER NOT NULL DEFAULT 0,
                    index_truncated INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX clip_embedding_pending ON clip_embedding_jobs(clip_id) WHERE status='pending';
                CREATE TABLE clip_embedding_chunks (
                    clip_id INTEGER NOT NULL REFERENCES clip_embedding_jobs(clip_id) ON DELETE CASCADE,
                    chunk_index INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    PRIMARY KEY(clip_id,chunk_index)
                );
                PRAGMA user_version=7;
                """)
            }
            if version < 8 {
                try execute("""
                ALTER TABLE payloads ADD COLUMN encoding INTEGER NOT NULL DEFAULT 0 CHECK(encoding IN (0,1));
                CREATE TABLE secret_storage (singleton INTEGER PRIMARY KEY CHECK(singleton=1), key_id TEXT NOT NULL, needs_cleanup INTEGER NOT NULL DEFAULT 0 CHECK(needs_cleanup IN (0,1)));
                PRAGMA user_version=8;
                """)
            }
            if version < 9 {
                // Unlike key metadata, maintenance must exist even in an old
                // database that has never stored an encrypted secret.
                try execute("""
                CREATE TABLE secret_maintenance (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    needs_checkpoint INTEGER NOT NULL CHECK(needs_checkpoint IN (0,1)),
                    needs_vacuum INTEGER NOT NULL CHECK(needs_vacuum IN (0,1))
                );
                INSERT INTO secret_maintenance VALUES(1,\(version > 0 ? 1 : 0),\(version > 0 ? 1 : 0));
                UPDATE secret_storage SET needs_cleanup=0;
                PRAGMA user_version=9;
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

    /// Keeps related reads on one SQLite snapshot. Nested readers share the caller's transaction.
    /// The store remains confined to its owning serial queue.
    public func withReadSnapshot<T>(_ body: () throws -> T) throws -> T {
        guard sqlite3_get_autocommit(db) != 0 else { return try body() }
        try execute("BEGIN")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func insert(payload: ClipPayload, kind: ClipKind, title: String, text: String,
                       source: String, isConcealed: Bool = false, isRemote: Bool = false,
                       date: Date = Date(), maxCount: Int = 50_000,
                       maxBytes: Int = 5_000_000_000) throws -> Int64 {
        guard !payload.items.isEmpty, payload.items.allSatisfy({ !$0.isEmpty }) else { throw HistoryError.invalidPayload }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let encoded = try encoder.encode(payload)
        let key = try insertionKey(payload, isConcealed: isConcealed)
        try execute("BEGIN IMMEDIATE")
        do {
            let stored = try prepareStoredPayload(payload, encoded: encoded, isConcealed: isConcealed, key: key)
            let fingerprint = stored.fingerprint, storedData = stored.data
            let effectiveConcealed = stored.isConcealed
            let storedTitle = effectiveConcealed ? Self.concealedTitle : title
            let storedText = effectiveConcealed ? "" : text
            let concealedSearch = Self.concealedSearch(source: source)
            let storedSearch = effectiveConcealed ? concealedSearch : SearchFilter.normalize(title + " " + text + " " + source)
            let statement = try prepare("""
                INSERT INTO clips(fingerprint,date,sort_date,kind,title,text,source,search,bytes,is_concealed,is_remote) VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(fingerprint) DO UPDATE SET date=excluded.date, sort_date=excluded.sort_date,
                    source=excluded.source, is_remote=excluded.is_remote, bytes=excluded.bytes,
                    is_concealed=MAX(clips.is_concealed,excluded.is_concealed),
                    title=CASE WHEN clips.is_concealed OR excluded.is_concealed THEN ? ELSE clips.title END,
                    text=CASE WHEN clips.is_concealed OR excluded.is_concealed THEN '' ELSE clips.text END,
                    search=CASE WHEN clips.is_concealed OR excluded.is_concealed THEN ? ELSE excluded.search END
                RETURNING id
                """)
            defer { sqlite3_finalize(statement) }
            try bind([.text(fingerprint), .number(date.timeIntervalSince1970), .number(date.timeIntervalSince1970), .text(kind.rawValue),
                      .text(storedTitle), .text(storedText), .text(source), .text(storedSearch),
                      .integer(Int64(storedData.count)), .integer(effectiveConcealed ? 1 : 0), .integer(isRemote ? 1 : 0),
                      .text(Self.concealedTitle), .text(concealedSearch)], to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            let id = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            let blob = try prepare("""
                INSERT INTO payloads(clip_id,data,encoding) VALUES(?,?,?)
                ON CONFLICT(clip_id) DO UPDATE SET data=excluded.data,encoding=excluded.encoding
                WHERE excluded.encoding=1
                """)
            defer { sqlite3_finalize(blob) }
            try bind([.integer(id), .blob(storedData), .integer(effectiveConcealed ? 1 : 0)], to: blob)
            guard sqlite3_step(blob) == SQLITE_DONE else { throw failure() }
            try syncImageTextJob(id: id)
            try syncEmbeddingJob(id: id)
            try prune(maxCount: maxCount, maxBytes: maxBytes)
            try execute("COMMIT")
            return id
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func search(_ filter: SearchFilter, limit: Int = 150, offset: Int = 0) throws -> [ClipSummary] {
        let (clause, bindings) = predicate(filter)
        return try summaries("SELECT \(Self.summaryColumns) FROM clips \(clause) ORDER BY sort_date DESC,id DESC LIMIT ? OFFSET ?",
                             bindings: bindings + [.integer(Int64(limit)), .integer(Int64(offset))])
    }

    /// Current metadata for a single record, without loading its clipboard payload.
    public func summary(id: Int64) throws -> ClipSummary {
        guard let result = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE id=?",
                                         bindings: [.integer(id)]).first else { throw HistoryError.missing }
        return result
    }

    /// Nearest captures across the whole history, newest first. Counts on either side are clamped to 0...100.
    /// "Before" means older captures; "after" means newer captures. Equal dates are ordered by ID.
    public func nearby(anchorID: Int64, before: Int = 10, after: Int = 10,
                       includeConcealed: Bool = true) throws -> [ClipSummary] {
        try withReadSnapshot {
            let visibility = includeConcealed ? "" : " AND is_concealed=0"
            let statement = try prepare("SELECT \(Self.summaryColumns) FROM clips WHERE id=?\(visibility)")
            defer { sqlite3_finalize(statement) }
            try bind([.integer(anchorID)], to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { throw HistoryError.missing }
            guard status == SQLITE_ROW else { throw failure() }
            let anchor = summary(statement)
            // Preserve SQLite's exact timestamp for the cursor, without a Foundation Date round trip.
            let cursor: [Value] = [.number(sqlite3_column_double(statement, 1)), .integer(anchorID)]
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            let older = try summaries("""
                SELECT \(Self.summaryColumns) FROM clips WHERE (date,id)<(?,?)\(visibility)
                ORDER BY date DESC,id DESC LIMIT ?
                """, bindings: cursor + [.integer(Int64(max(0, min(100, before))))])
            let newer = try summaries("""
                SELECT \(Self.summaryColumns) FROM clips WHERE (date,id)>(?,?)\(visibility)
                ORDER BY date ASC,id ASC LIMIT ?
                """, bindings: cursor + [.integer(Int64(max(0, min(100, after))))])
            return newer.reversed() + [anchor] + older
        }
    }

    /// Reads only visible content. Images expose cached OCR; binary image/other payloads are not loaded.
    public func visibleContent(id: Int64) throws -> ClipContent {
        try content(id: id, includeConcealed: false)
    }

    /// Explicit read of the original content, including concealed records. Does not remove concealment.
    public func revealedContent(id: Int64) throws -> ClipContent {
        try content(id: id, includeConcealed: true)
    }

    private func content(id: Int64, includeConcealed: Bool) throws -> ClipContent {
        let record: (ClipSummary, Data?, String?, Int32, String) = try withReadSnapshot {
            let columns = Self.summaryColumns.split(separator: ",").map { "clips.\($0)" }.joined(separator: ",")
            let visibility = includeConcealed ? "" : " AND clips.is_concealed=0"
            let statement = try prepare("""
                SELECT \(columns),payloads.data,clip_ocr.status,clip_ocr.text,payloads.encoding,clips.fingerprint
                FROM clips
                LEFT JOIN payloads ON payloads.clip_id=clips.id AND clips.kind IN ('text','link','file')
                LEFT JOIN clip_ocr ON clip_ocr.clip_id=clips.id AND clips.kind='image'
                WHERE clips.id=?\(visibility)
                """)
            defer { sqlite3_finalize(statement) }
            try bind([.integer(id)], to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { throw HistoryError.missing }
            guard status == SQLITE_ROW else { throw failure() }
            let clip = summary(statement)
            var data: Data?
            if [.text, .link, .file].contains(clip.kind) {
                guard let bytes = sqlite3_column_blob(statement, 10) else { throw HistoryError.invalidPayload }
                data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 10)))
            }
            let imageText = clip.kind == .image && string(statement, 11) == "complete" ? string(statement, 12) : nil
            let encoding = sqlite3_column_int(statement, 13)
            let fingerprint = string(statement, 14)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            return (clip, data, imageText, encoding, fingerprint)
        }
        // Release the read transaction before property-list decoding.
        let payload = try record.1.map { try decodePayload($0, encoding: record.3, fingerprint: record.4, concealed: record.0.isConcealed) }
        return ClipContent(summary: record.0, payload: payload, imageText: record.2)
    }

    func summaries(_ sql: String, bindings: [Value]) throws -> [ClipSummary] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [ClipSummary] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(summary(statement))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    func summary(_ statement: OpaquePointer) -> ClipSummary {
        ClipSummary(id: sqlite3_column_int64(statement, 0),
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            kind: ClipKind(rawValue: string(statement, 2)) ?? .other, title: string(statement, 3),
            text: string(statement, 4), source: string(statement, 5), byteCount: Int(sqlite3_column_int64(statement, 6)),
            isConcealed: sqlite3_column_int(statement, 7) != 0,
            isFavorite: sqlite3_column_int(statement, 8) != 0,
            isRemote: sqlite3_column_int(statement, 9) != 0)
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
        let statement = try prepare("SELECT DISTINCT source FROM clips WHERE source<>'' AND is_remote=0")
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
        let record = try storedPayload(id: id)
        return try decodePayload(record.data, encoding: record.encoding, fingerprint: record.fingerprint, concealed: record.concealed)
    }

    /// Copy both payload and privacy metadata in one statement, then release its
    /// read lock before decoding or asking the Keychain for access.
    func storedPayload(id: Int64) throws -> (data: Data, encoding: Int32, fingerprint: String, concealed: Bool) {
        let statement = try prepare("SELECT payloads.data,payloads.encoding,clips.fingerprint,clips.is_concealed FROM payloads JOIN clips ON clips.id=payloads.clip_id WHERE clip_id=?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw HistoryError.missing }
        guard status == SQLITE_ROW else { throw failure() }
        guard let bytes = sqlite3_column_blob(statement, 0) else { throw HistoryError.invalidPayload }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return (data, sqlite3_column_int(statement, 1), string(statement, 2), sqlite3_column_int(statement, 3) != 0)
    }

    public func delete(id: Int64) throws {
        let statement = try prepare("DELETE FROM clips WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    /// Call after a successful copy or drop. Usage changes ordering, never the capture date or metadata.
    public func markUsed(id: Int64, date: Date = Date()) throws {
        let statement = try prepare("UPDATE clips SET sort_date=? WHERE id=? RETURNING id")
        defer { sqlite3_finalize(statement) }
        try bind([.number(date.timeIntervalSince1970), .integer(id)], to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw HistoryError.missing }
        guard status == SQLITE_ROW else { throw failure() }
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
        _ = try summary(id: id)
        let key = try prepareSecretKey(create: true)
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
            try registerSecretKey(key)
            try encryptStoredPayload(id: id, key: key)
            let statement = try prepare("UPDATE clips SET is_concealed=1,title=?,text='',search=? WHERE id=?")
            defer { sqlite3_finalize(statement) }
            try bind([.text(Self.concealedTitle), .text(Self.concealedSearch(source: source)), .integer(id)], to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            try deleteImageText(id: id)
            try syncEmbeddingJob(id: id)
            // Metadata can contain plaintext even if a damaged record has lost
            // its payload. Concealment always leaves a durable cleanup request.
            try requestSecretCleanup()
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

    /// Completed visible image text, including an empty successful result.
    /// Pending, failed, concealed and non-image records return nil; missing records throw.
    public func imageText(id: Int64) throws -> String? {
        let statement = try prepare("""
            SELECT clips.kind,clips.is_concealed,clip_ocr.status,clip_ocr.text
            FROM clips LEFT JOIN clip_ocr ON clip_ocr.clip_id=clips.id WHERE clips.id=?
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.integer(id)], to: statement)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { throw HistoryError.missing }
        guard status == SQLITE_ROW else { throw failure() }
        let result = string(statement, 0) == ClipKind.image.rawValue && sqlite3_column_int(statement, 1) == 0 && string(statement, 2) == "complete"
            ? string(statement, 3) : nil
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return result
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
            default: throw HistoryError.database(L10n.text("Неизвестное состояние распознавания текста."))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return ImageTextProgress(pending: pending, complete: complete, failed: failed)
    }

    private func finishImageText(id: Int64, status: String, text: String, search: String) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            let changed = try updateImageText(id: id, status: status, text: text, search: search)
            if changed { try syncEmbeddingJob(id: id) }
            try execute("COMMIT")
            return changed
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func updateImageText(id: Int64, status: String, text: String, search: String) throws -> Bool {
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
        // Favorites are outside the automatic limits. Keep the most recently copied or used ordinary prefix.
        let statement = try prepare("""
            DELETE FROM clips WHERE id IN (
                SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (ORDER BY sort_date DESC,id DESC) AS position,
                    SUM(bytes) OVER (ORDER BY sort_date DESC,id DESC) AS total FROM clips WHERE is_favorite=0
                ) WHERE position > ? OR total > ?
            )
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.integer(Int64(max(1, maxCount))), .integer(Int64(max(1, maxBytes)))], to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    enum Value { case text(String), number(Double), integer(Int64), blob(Data) }
    func predicate(_ filter: SearchFilter) -> (String, [Value]) {
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
        if filter.remoteOnly { clauses.append("is_remote=1") }
        if filter.concealedOnly { clauses.append("is_concealed=1") }
        if filter.excludesConcealed { clauses.append("is_concealed=0") }
        if let from = filter.from { clauses.append("date>=?"); bindings.append(.number(from.timeIntervalSince1970)) }
        if let until = filter.until { clauses.append("date<?"); bindings.append(.number(until.timeIntervalSince1970)) }
        return (clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "), bindings)
    }

    func failure() -> HistoryError { .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.text("не удалось открыть файл")) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    func bind(_ values: [Value], to statement: OpaquePointer) throws {
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
    func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }
}
