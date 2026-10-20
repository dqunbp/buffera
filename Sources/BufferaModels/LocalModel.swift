import Foundation

public enum ModelRole: String, Codable, CaseIterable, Sendable {
    case embedding
    case assistant
}

public enum ModelState: String, Codable, Sendable {
    case notDownloaded, downloading, paused, verifying, downloaded, failed
}

public struct LocalModelDescriptor: Sendable {
    public let role: ModelRole
    public let title: String
    public let summary: String
    public let repository: String
    public let revision: String
    public let filename: String
    public let byteCount: Int64
    public let sha256: String
    public let sourceURL: URL
    public let licenseURL: URL

    public init(role: ModelRole, title: String, summary: String, repository: String,
                revision: String, filename: String, byteCount: Int64, sha256: String,
                sourceURL: URL, licenseURL: URL) {
        self.role = role
        self.title = title
        self.summary = summary
        self.repository = repository
        self.revision = revision
        self.filename = filename
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sourceURL = sourceURL
        self.licenseURL = licenseURL
    }
}

public struct LocalModelSnapshot: Sendable {
    public let descriptor: LocalModelDescriptor
    public let state: ModelState
    public let receivedBytes: Int64
    public let totalBytes: Int64
    /// The user has enabled the feature, including while its files are being prepared.
    public let isEnabled: Bool
    public let errorMessage: String?

    /// Runtimes may start only after verified files and the feature preference agree.
    public var isReadyForUse: Bool { isEnabled && state == .downloaded }

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

public enum LocalModelCatalog {
    public static let models: [LocalModelDescriptor] = [
        make(
            role: .embedding, title: "EmbeddingGemma 2",
            summary: "Модель для поиска по смыслу. Текстовая версия, Q8.",
            repository: "ggml-org/embeddinggemma-2-GGUF",
            revision: "58faf90940886df2d62be555c8765d00dac362c5",
            filename: "embeddinggemma-2-Q8_0.gguf", byteCount: 309_855_456,
            sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135"
        ),
        make(
            role: .assistant, title: "Gemma 4 E2B",
            summary: "Модель для локального помощника. Текстовая версия, Q4.",
            repository: "ggml-org/gemma-4-E2B-it-GGUF",
            revision: "6938c58e698502037401a5f19f6905f2fb2f7dee",
            filename: "gemma-4-E2B-it-Q4_0.gguf", byteCount: 2_841_481_184,
            sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
        )
    ]

    private static func make(role: ModelRole, title: String, summary: String,
                             repository: String, revision: String, filename: String,
                             byteCount: Int64, sha256: String) -> LocalModelDescriptor {
        LocalModelDescriptor(
            role: role, title: title, summary: summary, repository: repository,
            revision: revision, filename: filename, byteCount: byteCount, sha256: sha256,
            sourceURL: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!,
            licenseURL: URL(string: "https://huggingface.co/\(repository)/blob/\(revision)/README.md")!
        )
    }
}

enum ModelStorageError: LocalizedError {
    case invalidDescriptor
    case unsafeFile
    case invalidResponse
    case invalidRange
    case unexpectedSize
    case checksum
    case insufficientSpace
    case notDownloaded
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor: return "Не удалось определить, какие файлы нужны. Обновите Buffera."
        case .unsafeFile: return "В папке скачивания обнаружен неожиданный файл или ссылка."
        case .invalidResponse: return "Сервер вернул некорректный ответ."
        case .invalidRange: return "Сервер вернул неверный диапазон файла. Повторите загрузку."
        case .unexpectedSize: return "Размер скачанного файла не совпадает с ожидаемым."
        case .checksum: return "Проверка файла не пройдена. Повторите скачивание."
        case .insufficientSpace: return "Недостаточно свободного места для скачивания."
        case .notDownloaded: return "Нужные файлы ещё не скачаны и не проверены."
        case .http(let status): return "Сервер загрузки вернул ошибку \(status)."
        }
    }
}
