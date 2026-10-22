import Foundation
import BufferaCore
import CSQLite

private final class SecretFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { directory.appendingPathComponent("history.sqlite") }
    var store: HistoryStore!
    var keyAvailable = true
    var creations = 0
    var onKeyAccess: (() throws -> Void)?
    lazy var cipher = SecretPayloadCipher { [unowned self] _, create in
        try self.onKeyAccess?()
        if create { self.creations += 1 }
        guard self.keyAvailable else { throw SecretStorageError.keyUnavailable }
        return Data(repeating: 0x36, count: 32)
    }
    init() throws { store = try HistoryStore(url: url, secretCipher: cipher) }
    deinit { store = nil; try? FileManager.default.removeItem(at: directory) }
    func payload(_ value: String) -> ClipPayload {
        ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data(value.utf8)),
                             Representation(type: "fixture.custom", data: Data([0, 255, 4]))]])
    }
    @discardableResult func insert(_ value: String, secret: Bool = true) throws -> Int64 {
        try store.insert(payload: payload(value), kind: .text, title: value, text: value, source: "Fixture", isConcealed: secret)
    }
    func raw<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        try checkEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        return try body(db!)
    }
    func execute(_ sql: String) throws {
        try raw { try checkEqual(sqlite3_exec($0, sql, nil, nil, nil), SQLITE_OK) }
    }
    func scalar(_ sql: String) throws -> Int {
        try raw { db in
            var statement: OpaquePointer?
            try checkEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try checkEqual(sqlite3_step(statement), SQLITE_ROW)
            return Int(sqlite3_column_int(statement, 0))
        }
    }
    func stored(_ id: Int64) throws -> (data: Data, encoding: Int32, fingerprint: String) {
        try raw { db in
            var stmt: OpaquePointer?
            try checkEqual(sqlite3_prepare_v2(db, "SELECT data,encoding,fingerprint FROM payloads JOIN clips ON clips.id=payloads.clip_id WHERE clip_id=\(id)", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            try checkEqual(sqlite3_step(stmt), SQLITE_ROW)
            return (Data(bytes: sqlite3_column_blob(stmt, 0)!, count: Int(sqlite3_column_bytes(stmt, 0))),
                    sqlite3_column_int(stmt, 1), String(cString: sqlite3_column_text(stmt, 2)))
        }
    }
    func replace(_ id: Int64, data: Data) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try execute("UPDATE payloads SET data=X'\(hex)' WHERE clip_id=\(id)")
    }
}

func runSecretStorageChecks() -> Int {
    let checks: [(String, (SecretFixture) throws -> Void)] = [
        ("ordinary payloads are unchanged; default stores cannot write secrets", { f in
            let plain = try f.insert("ordinary-fixture", secret: false)
            let stored = try f.stored(plain)
            try checkEqual(stored.encoding, 0)
            try checkEqual(try PropertyListDecoder().decode(ClipPayload.self, from: stored.data), f.payload("ordinary-fixture"))
            let unprivileged = try HistoryStore(url: f.url)
            try checkThrows(try unprivileged.insert(payload: f.payload("secret"), kind: .text, title: "secret", text: "secret", source: "", isConcealed: true))
            try checkEqual(try f.store.count(), 1)
            try checkEqual(f.creations, 0)
        }),
        ("secrets round trip with authenticated encryption and keyed fingerprints", { f in
            let value = "unique-secret-fixture-92874"
            let id = try f.insert(value)
            let first = try f.stored(id)
            try checkEqual(first.encoding, 1)
            try check(first.data.range(of: Data(value.utf8)) == nil)
            try checkNotEqual(first.fingerprint, f.payload(value).fingerprint)
            try check(first.fingerprint.hasPrefix("secret-v1:"))
            try checkThrows(try PropertyListDecoder().decode(ClipPayload.self, from: first.data))
            try checkEqual(try f.store.payload(id: id), f.payload(value))
            try checkEqual(try f.store.revealedContent(id: id).payload, f.payload(value))
            try checkThrows(try f.store.visibleContent(id: id))
            try checkEqual(try f.insert(value), id)
            try checkNotEqual(try f.stored(id).data, first.data) // fresh nonce
            f.store = nil
            f.store = try HistoryStore(url: f.url, secretCipher: f.cipher)
            try checkEqual(try f.store.payload(id: id), f.payload(value))
            try checkEqual(f.creations, 1)
            for file in [f.url, URL(fileURLWithPath: f.url.path + "-wal")] where FileManager.default.fileExists(atPath: file.path) {
                let bytes = try Data(contentsOf: file)
                try check(bytes.range(of: Data(value.utf8)) == nil)
                try check(bytes.range(of: Data(f.payload(value).fingerprint.utf8)) == nil)
            }
        }),
        ("keyless readers see metadata but cannot reveal or copy secrets", { f in
            let id = try f.insert("unavailable-key-secret")
            let reader = try HistoryStore(url: f.url, mode: .readOnly)
            try check(try reader.summary(id: id).isConcealed)
            try checkThrows(try reader.payload(id: id))
            try checkThrows(try reader.revealedContent(id: id))
            try checkThrows(try reader.restorablePayload(id: id))
            f.keyAvailable = false
            try checkThrows(try f.store.prepareSecretStorage())
            try checkThrows(try f.store.payload(id: id))
            try checkThrows(try f.insert("cannot-save-secret"))
            let plain = try f.insert("ordinary-still-works", secret: false)
            try checkEqual(try f.store.payload(id: plain), f.payload("ordinary-still-works"))
            try checkEqual(f.creations, 1) // missing existing key never replaced
            try checkEqual(try f.store.count(), 2)
        }),
        ("lost key metadata never generates a replacement for encrypted records", { f in
            let id = try f.insert("existing-encrypted-record")
            try f.execute("DELETE FROM secret_storage")
            try checkThrows(try f.store.prepareSecretStorage())
            try checkThrows(try f.insert("second-secret"))
            try checkEqual(f.creations, 1)
            try checkEqual(try f.store.count(), 1)
            try checkEqual(try f.stored(id).encoding, 1)
        }),
        ("wrong keys, tampering and ciphertext swaps fail closed", { f in
            let a = try f.insert("secret-a"), b = try f.insert("secret-b")
            let wrong = try HistoryStore(url: f.url, mode: .readOnly,
                secretCipher: SecretPayloadCipher { _, _ in Data(repeating: 0x99, count: 32) })
            try checkThrows(try wrong.payload(id: a))
            var bytes = try f.stored(a).data
            bytes[bytes.count - 1] ^= 1
            try f.replace(a, data: bytes)
            try checkThrows(try f.store.payload(id: a))
            try f.replace(a, data: f.stored(b).data)
            try checkThrows(try f.store.payload(id: a))
            try checkEqual(try f.store.payload(id: b), f.payload("secret-b"))
        }),
        ("failed encryption rolls back concealment and new inserts", { f in
            let id = try f.insert("visible-before-failure", secret: false)
            f.keyAvailable = false
            try checkThrows(try f.store.conceal(id: id))
            try check(!f.store.summary(id: id).isConcealed)
            try checkEqual(try f.stored(id).encoding, 0)
            try checkThrows(try f.insert("never-in-database"))
            try checkEqual(try f.store.count(), 1)
            f.keyAvailable = true
            try f.store.conceal(id: id)
            try checkEqual(try f.stored(id).encoding, 1)
            try checkEqual(try f.store.payload(id: id), f.payload("visible-before-failure"))
            let copy = try f.store.restorablePayload(id: id)
            try check(copy.items.allSatisfy { $0.contains { $0.type == "org.nspasteboard.ConcealedType" } })
        }),
        ("legacy secrets stay unreadable until atomic upgrade; visible records survive", { f in
            let value = "legacy-secret-fixture-unique-18495"
            let id = try f.insert(value, secret: false)
            let ordinary = try f.insert("keep-normal", secret: false)
            try f.execute("UPDATE clips SET is_concealed=1,title='Скрытая запись',text='',search='' WHERE id=\(id)")
            f.keyAvailable = false
            try checkThrows(try f.store.protectLegacySecrets())
            try checkEqual(try f.stored(id).encoding, 0)
            try checkThrows(try f.store.payload(id: id))
            try checkEqual(try f.store.count(), 2)
            f.keyAvailable = true
            try f.store.protectLegacySecrets()
            try checkEqual(try f.stored(id).encoding, 1)
            try checkEqual(try f.store.payload(id: id), f.payload(value))
            try checkEqual(try f.store.payload(id: ordinary), f.payload("keep-normal"))
            try f.store.protectLegacySecrets() // idempotent
            try check(!f.store.performSecretMaintenance())
            for file in [f.url, URL(fileURLWithPath: f.url.path + "-wal")] where FileManager.default.fileExists(atPath: file.path) {
                let bytes = try Data(contentsOf: file)
                try check(bytes.range(of: Data(value.utf8)) == nil)
                try check(bytes.range(of: Data(f.payload(value).fingerprint.utf8)) == nil)
            }
        }),
        ("deduplication merges a visible copy created while key access was unavailable", { f in
            let value = "repeat-when-key-unavailable"
            let secret = try f.insert(value)
            f.keyAvailable = false
            let visible = try f.insert(value, secret: false)
            try f.store.setFavorite(id: visible, isFavorite: true)
            f.keyAvailable = true
            try checkEqual(try f.insert(value), secret)
            try checkEqual(try f.store.count(), 1)
            try check(try f.store.summary(id: secret).isFavorite)
            try checkEqual(try f.store.payload(id: secret), f.payload(value))
        }),
        ("key access never holds a write transaction or payload read snapshot", { f in
            f.onKeyAccess = { [unowned f] in
                try f.raw { db in
                    sqlite3_busy_timeout(db, 0)
                    // A write transaction or any active payload read snapshot
                    // on the store connection prevents this TRUNCATE.
                    try checkEqual(sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
                    try checkEqual(sqlite3_exec(db, "BEGIN IMMEDIATE; ROLLBACK", nil, nil, nil), SQLITE_OK)
                }
            }
            try f.store.prepareSecretStorage()
            let secret = try f.insert("preflight-secret")
            try checkEqual(try f.insert("preflight-secret", secret: false), secret)
            let ordinary = try f.insert("preflight-conceal", secret: false)
            try f.store.conceal(id: ordinary)
            _ = try f.store.payload(id: secret)
            _ = try f.store.restorablePayload(id: secret)
            _ = try f.store.revealedContent(id: secret)
            let legacy = try f.insert("preflight-legacy", secret: false)
            try f.execute("UPDATE clips SET is_concealed=1 WHERE id=\(legacy)")
            try f.store.protectLegacySecrets()
        }),
        ("key metadata SQL errors cannot save an open duplicate of a secret", { f in
            let id = try f.insert("protected-dedup-sql-failure")
            try f.execute("ALTER TABLE secret_storage RENAME COLUMN key_id TO broken_key_id")
            try checkThrows(try f.insert("protected-dedup-sql-failure", secret: false))
            try checkEqual(try f.store.count(), 1)
            try check(try f.store.summary(id: id).isConcealed)
            try f.execute("ALTER TABLE secret_storage RENAME COLUMN broken_key_id TO key_id")
            try checkEqual(try f.store.payload(id: id), f.payload("protected-dedup-sql-failure"))
        }),
        ("cleanup failure cannot turn committed concealment or promotion into failure", { f in
            try f.execute("""
                CREATE TRIGGER fail_cleanup BEFORE UPDATE ON secret_maintenance
                WHEN NEW.needs_checkpoint=0 BEGIN SELECT RAISE(ABORT,'fixture cleanup failure'); END;
                """)
            let id = try f.insert("commit-before-maintenance", secret: false)
            try f.store.conceal(id: id)
            try check(try f.store.summary(id: id).isConcealed)
            try check(f.store.performSecretMaintenance())
            try checkEqual(try f.stored(id).encoding, 1)
            let promoted = try f.insert("promotion-before-maintenance", secret: false)
            try checkEqual(try f.insert("promotion-before-maintenance"), promoted)
            try check(f.store.performSecretMaintenance())
            try checkEqual(try f.scalar("SELECT needs_checkpoint FROM secret_maintenance"), 1)
            try f.execute("DROP TRIGGER fail_cleanup")
            try check(!f.store.performSecretMaintenance())
        }),
        ("busy readers defer cleanup without blocking; retry erases plaintext without VACUUM", { f in
            let value = "checkpoint-secret-fixture-9382745"
            let id = try f.insert(value, secret: false)
            let schema = try f.scalar("PRAGMA schema_version")
            try f.raw { reader in
                try checkEqual(sqlite3_exec(reader, "BEGIN; SELECT * FROM clips", nil, nil, nil), SQLITE_OK)
                try f.store.conceal(id: id)
                let start = Date()
                try check(f.store.performSecretMaintenance())
                try check(Date().timeIntervalSince(start) < 1)
                try checkEqual(try f.scalar("SELECT needs_checkpoint FROM secret_maintenance"), 1)
                _ = try f.insert("ordinary-during-cleanup", secret: false)
                try checkEqual(sqlite3_exec(reader, "COMMIT", nil, nil, nil), SQLITE_OK)
            }
            // The durable request survives restart and does not require another secret operation.
            f.store = nil; f.store = try HistoryStore(url: f.url, secretCipher: f.cipher)
            try check(!f.store.performSecretMaintenance())
            try checkEqual(try f.scalar("PRAGMA schema_version"), schema) // VACUUM would change this.
            try checkEqual(try f.scalar("SELECT needs_checkpoint + needs_vacuum FROM secret_maintenance"), 0)
            for file in [f.url, URL(fileURLWithPath: f.url.path + "-wal")] where FileManager.default.fileExists(atPath: file.path) {
                try check(try Data(contentsOf: file).range(of: Data(value.utf8)) == nil)
            }
        }),
        ("concealment schedules metadata cleanup even when a damaged payload is missing", { f in
            let value = "metadata-without-payload-837492"
            let id = try f.insert(value, secret: false)
            try f.execute("DELETE FROM payloads WHERE clip_id=\(id)")
            try f.store.conceal(id: id)
            try check(try f.store.summary(id: id).isConcealed)
            try checkEqual(try f.scalar("SELECT needs_checkpoint FROM secret_maintenance"), 1)
            try check(!f.store.performSecretMaintenance())
            for file in [f.url, URL(fileURLWithPath: f.url.path + "-wal")] where FileManager.default.fileExists(atPath: file.path) {
                try check(try Data(contentsOf: file).range(of: Data(value.utf8)) == nil)
            }
        }),
        ("v8 migration vacuums old free pages even without key metadata, only once", { f in
            f.store = nil
            let marker = "old-deleted-secret-1928374"
            try f.execute("""
                PRAGMA secure_delete=OFF;
                CREATE TABLE old_data(value TEXT);
                INSERT INTO old_data VALUES('\(String(repeating: marker, count: 500))');
                DELETE FROM old_data;
                DROP TABLE old_data;
                DROP TABLE secret_maintenance;
                PRAGMA user_version=8;
                PRAGMA wal_checkpoint(TRUNCATE);
                """)
            try check(try Data(contentsOf: f.url).range(of: Data(marker.utf8)) != nil)
            f.store = try HistoryStore(url: f.url, secretCipher: f.cipher)
            try checkEqual(try f.scalar("SELECT COUNT(*) FROM secret_storage"), 0)
            try checkEqual(try f.scalar("SELECT needs_vacuum FROM secret_maintenance"), 1)
            try check(!f.store.performSecretMaintenance())
            let schema = try f.scalar("PRAGMA schema_version")
            try check(!f.store.performSecretMaintenance())
            try checkEqual(try f.scalar("PRAGMA schema_version"), schema)
            try checkEqual(f.creations, 0)
            for file in [f.url, URL(fileURLWithPath: f.url.path + "-wal")] where FileManager.default.fileExists(atPath: file.path) {
                try check(try Data(contentsOf: file).range(of: Data(marker.utf8)) == nil)
            }
        })
    ]
    var failures = 0
    for (name, body) in checks {
        do { try body(SecretFixture()); print("PASS: secret storage: \(name)") }
        catch { failures += 1; fputs("FAIL: secret storage: \(name): \(error)\n", stderr) }
    }
    print("\(checks.count - failures)/\(checks.count) secret storage checks passed")
    return failures
}
