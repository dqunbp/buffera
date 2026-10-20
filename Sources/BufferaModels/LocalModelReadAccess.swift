import BufferaLocalization
import Foundation

public enum EmbeddingConfiguration {
    public static let dimensions = 768
    public static let maximumInputBytes = 128 * 1024
    public static let maximumBatchCount = 4
    public static let documentTokenLimit = 512
    public static let documentTokenOverlap = 64
    public static let maximumDocumentChunks = 32
    public static let pipelineVersion =
        "embeddinggemma2-search-v1-doc\(documentTokenLimit)-overlap\(documentTokenOverlap)-max\(maximumDocumentChunks)-d\(dimensions)"

    public static func modelKey(descriptor: LocalModelDescriptor) -> String {
        "\(descriptor.repository)@\(descriptor.revision):\(descriptor.sha256):\(pipelineVersion)"
    }

    public static var fingerprint: String {
        modelKey(descriptor: LocalModelCatalog.models.first { $0.role == .embedding }!)
    }
}

public struct InstalledEmbeddingModel: Sendable {
    public let descriptor: LocalModelDescriptor
    public let fileURL: URL
    public var modelKey: String { EmbeddingConfiguration.modelKey(descriptor: descriptor) }
}

public enum EmbeddingRuntimeError: LocalizedError {
    case unavailable, disabled, invalidInput, invalidResponse, runtimeMissing, stopped, timedOut
    case worker(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("Поиск по смыслу ещё не готов: нужные файлы не скачаны или не прошли проверку.")
        case .disabled: return L10n.text("«Поиск по смыслу» выключен в настройках.")
        case .invalidInput: return L10n.text("Текст запроса слишком длинный или пустой.")
        case .invalidResponse: return L10n.text("Движок поиска вернул некорректный ответ.")
        case .runtimeMissing: return L10n.text("Движок поиска недоступен. Пересоберите или обновите Buffera.")
        case .stopped: return L10n.text("Поиск по смыслу остановлен.")
        case .timedOut: return L10n.text("Поиск по смыслу занял слишком много времени.")
        case .worker(let message): return L10n.diagnostic(message)
        }
    }
}

/// Reading availability never starts downloads, rewrites receipts, or opens clipboard history.
/// The GUI owns model management; MCP can use this reader without becoming a second writer.
public struct LocalModelReadAccess: Sendable {
    public let rootURL: URL
    public let descriptor: LocalModelDescriptor

    public init(rootURL: URL,
                descriptor: LocalModelDescriptor = LocalModelCatalog.models.first { $0.role == .embedding }!) {
        self.rootURL = rootURL
        self.descriptor = descriptor
    }

    public init(rootURL: URL, role: ModelRole) {
        self.init(rootURL: rootURL, descriptor: LocalModelCatalog.models.first { $0.role == role }!)
    }

    public func enabledEmbedding() throws -> InstalledEmbeddingModel {
        let fileURL = try enabledFileURL(role: .embedding, unavailable: EmbeddingRuntimeError.unavailable,
                                         disabled: EmbeddingRuntimeError.disabled)
        return InstalledEmbeddingModel(descriptor: descriptor, fileURL: fileURL)
    }

    public func enabledAssistant() throws -> InstalledAssistantModel {
        let fileURL = try enabledFileURL(role: .assistant, unavailable: ChatRuntimeError.unavailable,
                                         disabled: ChatRuntimeError.disabled)
        return InstalledAssistantModel(descriptor: descriptor, fileURL: fileURL)
    }

    private func enabledFileURL(role: ModelRole, unavailable: Error, disabled: Error) throws -> URL {
        try ModelStorage.validate(descriptor)
        guard descriptor.role == role else { throw unavailable }
        let roleDirectory = rootURL.appendingPathComponent(role.rawValue)
        let revisionDirectory = roleDirectory.appendingPathComponent(descriptor.revision)
        for directory in [rootURL, roleDirectory, revisionDirectory] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw unavailable
            }
        }
        let receiptURL = rootURL.appendingPathComponent("state.json")
        guard let receiptSize = try? ModelStorage.fileSize(receiptURL),
              receiptSize > 0, receiptSize <= 16_384,
              let bytes = try? Data(contentsOf: receiptURL),
              let receipts = try? JSONDecoder().decode([String: ModelReceipt].self, from: bytes),
              let receipt = receipts[role.rawValue],
              receipt.revision == descriptor.revision, receipt.sha256 == descriptor.sha256,
              receipt.state == .downloaded else {
            throw unavailable
        }
        guard receipt.enabled else { throw disabled }
        let fileURL = revisionDirectory.appendingPathComponent(descriptor.filename)
        guard (try? ModelStorage.fileSize(fileURL)) == descriptor.byteCount else {
            throw unavailable
        }
        return fileURL
    }
}
