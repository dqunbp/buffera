import Foundation

public enum ChatConfiguration {
    public static let contextTokens = 8192
    public static let maximumPromptTokens = 7168
    public static let maximumOutputTokens = 1024
    public static let maximumMessages = 13
    public static let maximumInputBytes = 128 * 1024

    public static func modelKey(descriptor: LocalModelDescriptor) -> String {
        "\(descriptor.repository)@\(descriptor.revision):\(descriptor.sha256):gemma4-text-v1"
    }
}

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

public struct ChatMessage: Codable, Sendable {
    public let role: ChatRole
    public let content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public enum ChatResponseFormat: String, Codable, Sendable {
    case text, json
}

public enum ChatStopReason: String, Codable, Sendable {
    case completed, length
}

public struct ChatGeneration: Sendable {
    public let text: String
    public let stopReason: ChatStopReason
    public let inputTokens: Int
    public let outputTokens: Int

    public init(text: String, stopReason: ChatStopReason, inputTokens: Int, outputTokens: Int) {
        self.text = text
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct InstalledAssistantModel: Sendable {
    public let descriptor: LocalModelDescriptor
    public let fileURL: URL
    public var modelKey: String { ChatConfiguration.modelKey(descriptor: descriptor) }
}

public enum ChatRuntimeError: LocalizedError {
    case unavailable, disabled, invalidInput, contextTooLong, invalidResponse
    case runtimeMissing, stopped, timedOut
    case worker(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Модель помощника ещё не скачана или не прошла проверку."
        case .disabled: return "Локальный помощник выключен в настройках моделей."
        case .invalidInput: return "Не удалось подготовить сообщения для помощника."
        case .contextTooLong: return "В запросе слишком много текста для локального помощника."
        case .invalidResponse: return "Движок помощника вернул некорректный ответ."
        case .runtimeMissing: return "Движок помощника недоступен. Пересоберите или обновите Buffera."
        case .stopped: return "Локальный помощник остановлен."
        case .timedOut: return "Ответ локального помощника занял слишком много времени."
        case .worker(let message): return message
        }
    }
}
