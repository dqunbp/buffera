import Foundation
import Security
import BufferaCore

/// Uses only a disposable Keychain and synthetic contents, never the login Keychain.
func runSecretKeychainSmokeTest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Buffera.KeychainTest.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let password = UUID().uuidString
    var keychain: SecKeychain?
    let status = password.withCString {
        SecKeychainCreate(directory.appendingPathComponent("test.keychain-db").path,
                          UInt32(password.utf8.count), $0, false, nil, &keychain)
    }
    guard status == errSecSuccess, let keychain else {
        throw HistoryError.database("Isolated Keychain creation failed: \(status)")
    }
    defer { SecKeychainDelete(keychain) }
    let first = KeychainSecretKeyProvider(keychain: keychain)
    let identifier = UUID().uuidString
    let key = try first.key(identifier: identifier, create: true)
    let reopened = KeychainSecretKeyProvider(keychain: keychain)
    guard key.count == 32, try reopened.key(identifier: identifier, create: false) == key else {
        throw HistoryError.database("Isolated Keychain round trip failed")
    }
    func expectUnavailable(_ message: String, _ read: () throws -> Data) throws {
        do {
            _ = try read()
            throw HistoryError.database(message)
        } catch SecretStorageError.keyUnavailable { }
    }
    let missingIdentifier = UUID().uuidString
    try expectUnavailable("Missing key was silently regenerated") {
        try reopened.key(identifier: missingIdentifier, create: false)
    }
    let recoveryProvider = KeychainSecretKeyProvider(keychain: keychain)
    let recoveredKey = try recoveryProvider.key(identifier: missingIdentifier, create: true)
    try expectUnavailable("Unavailable key access retried without an explicit request") {
        try reopened.key(identifier: missingIdentifier, create: false)
    }
    // New provisional IDs must not evade the failed-access cache or create keys.
    let blockedIdentifier = UUID().uuidString
    try expectUnavailable("A new identifier bypassed the failed-access cache") {
        try reopened.key(identifier: blockedIdentifier, create: true)
    }
    let verifier = KeychainSecretKeyProvider(keychain: keychain)
    try expectUnavailable("Blocked access created an unexpected Keychain item") {
        try verifier.key(identifier: blockedIdentifier, create: false)
    }
    guard try reopened.key(identifier: identifier, create: false) == key else {
        throw HistoryError.database("Failed access discarded a successfully cached key")
    }
    reopened.retryAccess()
    guard try reopened.key(identifier: missingIdentifier, create: false) == recoveredKey,
          try reopened.key(identifier: identifier, create: false) == key else {
        throw HistoryError.database("Explicit retry failed to recover the existing key")
    }
    let url = directory.appendingPathComponent("history.sqlite")
    var store: HistoryStore? = try HistoryStore(url: url, secretCipher: SecretPayloadCipher(keyProvider: first.key))
    let payload = ClipPayload(items: [[Representation(type: "public.utf8-plain-text", data: Data("keychain-test-fixture".utf8))]])
    let id = try store!.insert(payload: payload, kind: .text, title: "fixture", text: "fixture", source: "Test", isConcealed: true)
    store = nil
    let freshProvider = KeychainSecretKeyProvider(keychain: keychain)
    store = try HistoryStore(url: url, secretCipher: SecretPayloadCipher(keyProvider: freshProvider.key))
    guard try store!.payload(id: id) == payload else { throw HistoryError.invalidPayload }
    let keyless = try HistoryStore(url: url, mode: .readOnly)
    do {
        _ = try keyless.payload(id: id)
        throw HistoryError.database("Keyless reader decrypted a secret")
    } catch SecretStorageError.keyUnavailable { }
}
