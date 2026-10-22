import Foundation
import CryptoKit
import BufferaLocalization

public enum SecretStorageError: LocalizedError {
    case keyUnavailable, invalidCiphertext, legacyPayload
    public var errorDescription: String? {
        switch self {
        case .keyUnavailable: return L10n.text("Ключ секретов недоступен. Проверьте доступ Buffera к Связке ключей. Секрет не будет сохранён открытым.")
        case .invalidCiphertext: return L10n.text("Не удалось расшифровать секрет: ключ не подходит или данные повреждены.")
        case .legacyPayload: return L10n.text("Сначала разрешите Buffera зашифровать ранее сохранённые секреты.")
        }
    }
}

/// Key access is injected only by the app. Readers such as MCP have no provider.
/// Confined to the same serial queue as HistoryStore.
public final class SecretPayloadCipher {
    public typealias KeyProvider = (_ identifier: String, _ create: Bool) throws -> Data
    private let provider: KeyProvider
    public init(keyProvider: @escaping KeyProvider) { provider = keyProvider }

    /// Resolve external key access before entering a storage transaction. The
    /// prepared value performs cryptography without calling the provider again.
    func prepare(identifier: String, create: Bool = false) throws -> PreparedKey {
        let data = try provider(identifier, create)
        guard data.count == 32 else { throw SecretStorageError.keyUnavailable }
        return PreparedKey(identifier: identifier, master: SymmetricKey(data: data))
    }

    struct PreparedKey {
        let identifier: String
        private let fingerprintKey: SymmetricKey
        private let encryptionKey: SymmetricKey

        fileprivate init(identifier: String, master: SymmetricKey) {
            self.identifier = identifier
            func derive(_ purpose: String) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("Buffera.secret.v1".utf8),
                                      info: Data(purpose.utf8), outputByteCount: 32)
            }
            fingerprintKey = derive("fingerprint")
            encryptionKey = derive("encryption")
        }

        func fingerprint(_ plain: String) -> String {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(("Buffera.secret.fingerprint.v1:" + plain).utf8),
                                                     using: fingerprintKey)
            return "secret-v1:" + mac.map { String(format: "%02x", $0) }.joined()
        }

        private func context(_ fingerprint: String) -> Data { Data(("Buffera.payload.aes-gcm.v1:" + fingerprint).utf8) }

        func seal(_ data: Data, fingerprint: String) throws -> Data {
            // CryptoKit generates a fresh random nonce for every write.
            let box = try AES.GCM.seal(data, using: encryptionKey, authenticating: context(fingerprint))
            guard let combined = box.combined else { throw SecretStorageError.invalidCiphertext }
            return combined
        }

        func open(_ data: Data, fingerprint: String) throws -> Data {
            do {
                return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryptionKey, authenticating: context(fingerprint))
            } catch { throw SecretStorageError.invalidCiphertext }
        }
    }
}
