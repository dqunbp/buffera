import Foundation
import CSQLite

extension HistoryStore {
    struct StoredPayload {
        let data: Data
        let fingerprint: String
        let isConcealed: Bool
    }

    /// Runs inside insert's write transaction, including any deduplication changes.
    func prepareStoredPayload(_ payload: ClipPayload, encoded: Data, isConcealed: Bool) throws -> StoredPayload {
        var fingerprint = payload.fingerprint
        let originalMatch = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE fingerprint=?", bindings: [.text(fingerprint)])
        var effectiveConcealed = isConcealed || originalMatch.first?.isConcealed == true
        // Visible captures remain usable without Keychain. If a protected match
        // can be found, preserve concealment just as ordinary deduplication does.
        let protectedFingerprint: String?
        if effectiveConcealed {
            guard let secretCipher else { throw SecretStorageError.keyUnavailable }
            protectedFingerprint = try secretCipher.fingerprint(fingerprint, identifier: secretKeyIdentifier(create: true))
        } else {
            protectedFingerprint = try? secretCipher?.fingerprint(fingerprint, identifier: secretKeyIdentifier())
        }
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
                if !originalMatch.isEmpty { try execute("UPDATE secret_storage SET needs_cleanup=1 WHERE singleton=1") }
            }
        }
        let storedData: Data
        if effectiveConcealed {
            guard let secretCipher else { throw SecretStorageError.keyUnavailable }
            storedData = try secretCipher.seal(encoded, fingerprint: fingerprint, identifier: secretKeyIdentifier(create: true))
        } else { storedData = encoded }
        return StoredPayload(data: storedData, fingerprint: fingerprint, isConcealed: effectiveConcealed)
    }

    func secretKeyIdentifier(create: Bool = false) throws -> String {
        guard let secretCipher else { throw SecretStorageError.keyUnavailable }
        let statement = try prepare("SELECT key_id FROM secret_storage WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return string(statement, 0) }
        guard status == SQLITE_DONE else { throw failure() }
        guard create else { throw SecretStorageError.keyUnavailable }
        let encrypted = try prepare("SELECT 1 FROM payloads WHERE encoding=1 LIMIT 1")
        defer { sqlite3_finalize(encrypted) }
        let encryptedStatus = sqlite3_step(encrypted)
        guard encryptedStatus == SQLITE_DONE else {
            if encryptedStatus == SQLITE_ROW { throw SecretStorageError.keyUnavailable }
            throw failure()
        }
        let identifier = UUID().uuidString
        // Persist the key before committing its identifier. A failed transaction can
        // leave an unused Keychain item, but never a database that references a lost key.
        try secretCipher.prepare(identifier: identifier, create: true)
        let insert = try prepare("INSERT INTO secret_storage(singleton,key_id) VALUES(1,?)")
        defer { sqlite3_finalize(insert) }
        try bind([.text(identifier)], to: insert)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
        return identifier
    }

    /// Called on explicit enable. An existing key is NEVER replaced when missing.
    public func prepareSecretStorage() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let identifier = try secretKeyIdentifier(create: true)
            try secretCipher?.prepare(identifier: identifier, create: false)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try protectLegacySecrets()
    }

    /// Upgrade old concealed plaintext without deleting it or exposing it to readers.
    /// No Keychain access is needed if no legacy secrets exist.
    public func protectLegacySecrets() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let rows = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE is_concealed=1 AND id IN (SELECT clip_id FROM payloads WHERE encoding=0)", bindings: [])
            for row in rows { try encryptStoredPayload(id: row.id) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        try cleanupSecretRemnants()
    }

    /// If another connection holds a read snapshot, retain the durable cleanup
    /// flag and retry later. Checkpoint cannot erase pages still used by a reader.
    func cleanupSecretRemnants() throws {
        let statement = try prepare("SELECT needs_cleanup FROM secret_storage WHERE singleton=1")
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return }
        guard status == SQLITE_ROW else { throw failure() }
        let needed = sqlite3_column_int(statement, 0) != 0
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        guard needed else { return }
        let checkpoint = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if checkpoint == SQLITE_BUSY { return }
        guard checkpoint == SQLITE_OK else { throw failure() }
        try execute("VACUUM")
        let final = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if final == SQLITE_BUSY { return }
        guard final == SQLITE_OK else { throw failure() }
        try execute("UPDATE secret_storage SET needs_cleanup=0 WHERE singleton=1")
    }

    func encryptStoredPayload(id: Int64) throws {
        guard let secretCipher else { throw SecretStorageError.keyUnavailable }
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
        let identifier = try secretKeyIdentifier(create: true)
        let fingerprint = try secretCipher.fingerprint(payload.fingerprint, identifier: identifier)
        let encrypted = try secretCipher.seal(data, fingerprint: fingerprint, identifier: identifier)
        let duplicates = try summaries("SELECT \(Self.summaryColumns) FROM clips WHERE fingerprint=? AND id<>?",
                                       bindings: [.text(fingerprint), .integer(id)])
        for duplicate in duplicates {
            if duplicate.isFavorite { try setFavorite(id: id, isFavorite: true) }
            try delete(id: duplicate.id)
        }
        try execute("UPDATE secret_storage SET needs_cleanup=1 WHERE singleton=1")
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
            guard concealed, let secretCipher else { throw SecretStorageError.keyUnavailable }
            plain = try secretCipher.open(data, fingerprint: fingerprint, identifier: secretKeyIdentifier())
        default: throw HistoryError.invalidPayload
        }
        return try PropertyListDecoder().decode(ClipPayload.self, from: plain)
    }

    /// Re-copying a manually hidden entry must preserve its privacy marker.
    public func restorablePayload(id: Int64) throws -> ClipPayload {
        try withReadSnapshot {
            let payload = try payload(id: id)
            guard try summary(id: id).isConcealed else { return payload }
            return ClipPayload(items: payload.items.map { item in
                guard !item.contains(where: { $0.type == "org.nspasteboard.ConcealedType" }) else { return item }
                return item + [Representation(type: "org.nspasteboard.ConcealedType", data: Data())]
            })
        }
    }
}
