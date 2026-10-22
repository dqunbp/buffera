import Foundation
import BufferaCore
import CSQLite

private final class SecretFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { directory.appendingPathComponent("history.sqlite") }
    var store: HistoryStore!
    var keyAvailable = true
    var creations = 0
    lazy var cipher = SecretPayloadCipher { [unowned self] _, create in
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
