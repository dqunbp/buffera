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

    private func key(_ identifier: String, create: Bool = false) throws -> SymmetricKey {
        let data = try provider(identifier, create)
        guard data.count == 32 else { throw SecretStorageError.keyUnavailable }
        return SymmetricKey(data: data)
    }

    func prepare(identifier: String, create: Bool) throws { _ = try key(identifier, create: create) }

    private func derivedKey(_ identifier: String, purpose: String) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: try key(identifier), salt: Data("Buffera.secret.v1".utf8),
                              info: Data(purpose.utf8), outputByteCount: 32)
    }

    func fingerprint(_ plain: String, identifier: String) throws -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(("Buffera.secret.fingerprint.v1:" + plain).utf8),
                                                 using: try derivedKey(identifier, purpose: "fingerprint"))
        return "secret-v1:" + mac.map { String(format: "%02x", $0) }.joined()
    }

    private func context(_ fingerprint: String) -> Data { Data(("Buffera.payload.aes-gcm.v1:" + fingerprint).utf8) }

    func seal(_ data: Data, fingerprint: String, identifier: String) throws -> Data {
        // CryptoKit generates a fresh random nonce for every write.
        let box = try AES.GCM.seal(data, using: derivedKey(identifier, purpose: "encryption"), authenticating: context(fingerprint))
        guard let combined = box.combined else { throw SecretStorageError.invalidCiphertext }
        return combined
    }

    func open(_ data: Data, fingerprint: String, identifier: String) throws -> Data {
        let key = try derivedKey(identifier, purpose: "encryption")
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: context(fingerprint))
        } catch { throw SecretStorageError.invalidCiphertext }
    }
}
