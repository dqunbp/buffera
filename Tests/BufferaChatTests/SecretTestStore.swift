import Foundation
import BufferaCore

// Test-only deterministic key. Production has no default key provider.
func makeTestHistoryStore(url: URL, mode: HistoryStore.OpenMode = .readWrite) throws -> HistoryStore {
    let cipher = SecretPayloadCipher { _, _ in Data(repeating: 0x42, count: 32) }
    let store = try HistoryStore(url: url, mode: mode, secretCipher: cipher)
    if mode == .readWrite { try store.protectLegacySecrets() }
    return store
}
