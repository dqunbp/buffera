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
    do {
        _ = try reopened.key(identifier: UUID().uuidString, create: false)
        throw HistoryError.database("Missing key was silently regenerated")
    } catch SecretStorageError.keyUnavailable { }
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
