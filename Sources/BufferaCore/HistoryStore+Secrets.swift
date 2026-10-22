import Foundation
import CSQLite

extension HistoryStore {
    struct StoredPayload {
        let data: Data
        let fingerprint: String
        let isConcealed: Bool
    }

    /// Key access happens before BEGIN; only keyUnavailable permits ordinary
    /// captures to proceed without protected deduplication.
    func insertionKey(_ payload: ClipPayload, isConcealed: Bool) throws -> SecretPayloadCipher.PreparedKey? {
        let original = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE fingerprint=?", bindings: [.text(payload.fingerprint)])
        let required = isConcealed || original.first?.isConcealed == true
        do { return try prepareSecretKey(create: required) }
        catch SecretStorageError.keyUnavailable {
            if required { throw SecretStorageError.keyUnavailable }
            return nil
        }
    }

    /// Runs inside insert's write transaction, including any deduplication changes.
    func prepareStoredPayload(_ payload: ClipPayload, encoded: Data, isConcealed: Bool,
                              key: SecretPayloadCipher.PreparedKey?) throws -> StoredPayload {
        var fingerprint = payload.fingerprint
        let originalMatch = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE fingerprint=?", bindings: [.text(fingerprint)])
        var effectiveConcealed = isConcealed || originalMatch.first?.isConcealed == true
        if let key { try registerSecretKey(key) }
        let protectedFingerprint = key?.fingerprint(fingerprint)
        if let protectedFingerprint {
            let existing = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE fingerprint=?", bindings: [.text(protectedFingerprint)])
            if effectiveConcealed || !existing.isEmpty {
                effectiveConcealed = true
                // A visible copy may have been captured while the key was unavailable.
                // Merge it into the protected row rather than hitting the unique constraint.
                if let protected = existing.first, let original = originalMatch.first {
                    if original.isFavorite { try setFavorite(id: protected.id, isFavorite: true) }
                    try delete(id: original.id)
                }
                // Promote an existing visible row, preserving its ID and favorite.
                let promote = try prepare("UPDATE clips SET fingerprint=? WHERE fingerprint=?")
                defer { sqlite3_finalize(promote) }
                try bind([.text(protectedFingerprint), .text(fingerprint)], to: promote)
                guard sqlite3_step(promote) == SQLITE_DONE else { throw failure() }
                fingerprint = protectedFingerprint
                if !originalMatch.isEmpty { try requestSecretCleanup() }
            }
        }
        let storedData: Data
        if effectiveConcealed {
            guard let key else { throw SecretStorageError.keyUnavailable }
            storedData = try key.seal(encoded, fingerprint: fingerprint)
        } else { storedData = encoded }
        return StoredPayload(data: storedData, fingerprint: fingerprint, isConcealed: effectiveConcealed)
    }

    private func storedSecretKeyIdentifier() throws -> String? {
        let statement = try prepare("SELECT key_id FROM secret_storage WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return string(statement, 0) }
        guard status == SQLITE_DONE else { throw failure() }
        return nil
    }

    private func requireNoEncryptedPayloads() throws {
        let encrypted = try prepare("SELECT 1 FROM payloads WHERE encoding=1 LIMIT 1")
        defer { sqlite3_finalize(encrypted) }
        let encryptedStatus = sqlite3_step(encrypted)
        guard encryptedStatus == SQLITE_DONE else {
            if encryptedStatus == SQLITE_ROW { throw SecretStorageError.keyUnavailable }
            throw failure()
        }
    }

    /// All statements finish before the external provider is called.
    func prepareSecretKey(create: Bool = false) throws -> SecretPayloadCipher.PreparedKey {
        guard let secretCipher else { throw SecretStorageError.keyUnavailable }
        if let identifier = try storedSecretKeyIdentifier() { return try secretCipher.prepare(identifier: identifier) }
        guard create else { throw SecretStorageError.keyUnavailable }
        try requireNoEncryptedPayloads()
        return try secretCipher.prepare(identifier: UUID().uuidString, create: true)
    }

    /// Recheck identity under the write lock. Another writer cannot make us use
    /// a prepared key for the wrong database identity. Key creation itself may
    /// leave an unused Keychain item after rollback, but never replaces a lost key.
    func registerSecretKey(_ key: SecretPayloadCipher.PreparedKey) throws {
        if let identifier = try storedSecretKeyIdentifier() {
            guard identifier == key.identifier else { throw SecretStorageError.keyUnavailable }
            return
        }
        try requireNoEncryptedPayloads()
        let insert = try prepare("INSERT INTO secret_storage(singleton,key_id) VALUES(1,?)")
        defer { sqlite3_finalize(insert) }
        try bind([.text(key.identifier)], to: insert)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    /// Called on explicit enable. An existing key is NEVER replaced when missing.
    public func prepareSecretStorage() throws {
        let key = try prepareSecretKey(create: true)
        try execute("BEGIN IMMEDIATE")
        do {
            try registerSecretKey(key)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try protectLegacySecrets()
    }

    /// Upgrade old concealed plaintext without deleting it or exposing it to readers.
    /// No Keychain access is needed if no legacy secrets exist.
    public func protectLegacySecrets() throws {
        let query = "SELECT \(Self.summaryColumns) FROM clips WHERE is_concealed=1 AND id IN (SELECT clip_id FROM payloads WHERE encoding=0)"
        guard try !summaries(query, bindings: []).isEmpty else { return }
        let key = try prepareSecretKey(create: true)
        try execute("BEGIN IMMEDIATE")
        do {
            try registerSecretKey(key)
            let rows = try summaries(query, bindings: [])
            for row in rows { try encryptStoredPayload(id: row.id, key: key) }
            if !rows.isEmpty { try requestSecretCleanup(includingLegacy: true) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func encryptStoredPayload(id: Int64, key: SecretPayloadCipher.PreparedKey) throws {
        let row = try prepare("SELECT data,encoding FROM payloads WHERE clip_id=?")
        defer { sqlite3_finalize(row) }
        try bind([.integer(id)], to: row)
        let status = sqlite3_step(row)
        // A damaged record without a payload still needs its metadata/OCR hidden.
        if status == SQLITE_DONE { return }
        guard status == SQLITE_ROW else { throw failure() }
        if sqlite3_column_int(row, 1) == 1 { return }
        guard sqlite3_column_int(row, 1) == 0, let bytes = sqlite3_column_blob(row, 0) else { throw HistoryError.invalidPayload }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 0)))
        guard sqlite3_step(row) == SQLITE_DONE else { throw failure() }
        let payload = try PropertyListDecoder().decode(ClipPayload.self, from: data)
        let fingerprint = key.fingerprint(payload.fingerprint)
        let encrypted = try key.seal(data, fingerprint: fingerprint)
        let duplicates = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE fingerprint=? AND id<>?",
                                       bindings: [.text(fingerprint), .integer(id)])
        for duplicate in duplicates {
            if duplicate.isFavorite { try setFavorite(id: id, isFavorite: true) }
            try delete(id: duplicate.id)
        }
        let update = try prepare("UPDATE payloads SET data=?,encoding=1 WHERE clip_id=?")
        defer { sqlite3_finalize(update) }
        try bind([.blob(encrypted), .integer(id)], to: update)
        guard sqlite3_step(update) == SQLITE_DONE else { throw failure() }
        let metadata = try prepare("UPDATE clips SET fingerprint=?,bytes=? WHERE id=?")
        defer { sqlite3_finalize(metadata) }
        try bind([.text(fingerprint), .integer(Int64(encrypted.count)), .integer(id)], to: metadata)
        guard sqlite3_step(metadata) == SQLITE_DONE else { throw failure() }
    }

    func decodePayload(_ data: Data, encoding: Int32, fingerprint: String, concealed: Bool) throws -> ClipPayload {
        let plain: Data
        switch encoding {
        case 0:
            guard !concealed else { throw SecretStorageError.legacyPayload }
            plain = data
        case 1:
            guard concealed else { throw SecretStorageError.keyUnavailable }
            plain = try prepareSecretKey().open(data, fingerprint: fingerprint)
        default: throw HistoryError.invalidPayload
        }
        return try PropertyListDecoder().decode(ClipPayload.self, from: plain)
    }

    /// Re-copying a manually hidden entry must preserve its privacy marker.
    public func restorablePayload(id: Int64) throws -> ClipPayload {
        let record = try storedPayload(id: id)
        let payload = try decodePayload(record.data, encoding: record.encoding, fingerprint: record.fingerprint, concealed: record.concealed)
        guard record.concealed else { return payload }
        return ClipPayload(items: payload.items.map { item in
            guard !item.contains(where: { $0.type == "org.nspasteboard.ConcealedType" }) else { return item }
            return item + [Representation(type: "org.nspasteboard.ConcealedType", data: Data())]
        })
    }
}
