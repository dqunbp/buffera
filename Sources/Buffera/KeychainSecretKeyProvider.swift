import Foundation
import Security
import CryptoKit
import BufferaCore

/// File-based macOS Keychain, restricted to this application by its ACL.
/// The MCP executable never constructs this provider or receives a key.
final class KeychainSecretKeyProvider {
    private var cache: [String: Data] = [:]
    private let keychain: SecKeychain?
    init(keychain: SecKeychain? = nil) { self.keychain = keychain }
    private let service = "app.buffera.secret-history.v1"

    func key(identifier: String, create: Bool) throws -> Data {
        if let cached = cache[identifier] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier
        ]
        var read = query
        if let keychain { read[kSecMatchSearchList as String] = [keychain] }
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            cache[identifier] = data
            return data
        }
        // An absent existing key, denied access or a locked Keychain cannot be
        // repaired by silently generating a replacement key.
        guard status == errSecItemNotFound, create else { throw SecretStorageError.keyUnavailable }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var application: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &application) == errSecSuccess, let application else {
            throw SecretStorageError.keyUnavailable
        }
        var access: SecAccess?
        guard SecAccessCreate("Buffera secret history" as CFString, [application] as CFArray, &access) == errSecSuccess,
              let access else { throw SecretStorageError.keyUnavailable }
        var add = query
        if let keychain { add[kSecUseKeychain as String] = keychain }
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Buffera secret history"
        add[kSecAttrAccess as String] = access
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SecretStorageError.keyUnavailable }
        cache[identifier] = data
        return data
    }
}
