import Foundation
import BufferaModels

public struct ChatSource: Sendable, Equatable {
    public let number: Int
    public let id: Int64
    public let title: String
    public let copiedAt: Date
    public let application: String

    public init(number: Int, id: Int64, title: String, copiedAt: Date, application: String) {
        self.number = number; self.id = id; self.title = title
        self.copiedAt = copiedAt; self.application = application
    }
}

public enum ChatEvent: Sendable {
    case status(String)
    case token(String)
    case sources([ChatSource])
}

public struct ChatTurnResult: Sendable {
    public let answer: String
    public let sources: [ChatSource]
    public let truncated: Bool
}

public enum ChatSessionError: LocalizedError {
    case emptyQuestion, questionTooLong, busy, historyChanged, unavailable, emptyAnswer

    public var errorDescription: String? {
        switch self {
        case .emptyQuestion: return "Напишите вопрос об истории."
        case .questionTooLong: return "Вопрос слишком длинный. Оставьте до 2000 символов."
        case .busy: return "Дождитесь ответа или остановите его."
        case .historyChanged:
            return "Одна из найденных записей удалена или скрыта. Разговор сброшен; задайте вопрос ещё раз."
        case .unavailable: return "Не удалось прочитать историю. Попробуйте ещё раз."
        case .emptyAnswer: return "Модель не вернула ответ. Попробуйте уточнить вопрос."
        }
    }
}

/// The deterministic boundary used by fixture checks; production always uses ChatRuntime.
public typealias ChatGenerationProvider = @Sendable (
    [ChatMessage], Int, ChatResponseFormat, @escaping @Sendable (String) -> Void
) async throws -> ChatGeneration

func chatPrefix(_ value: String, characters: Int, bytes: Int) -> String {
    var result = ""
    var count = 0
    var usedBytes = 0
    for character in value {
        let text = String(character)
        guard count < characters, usedBytes + text.utf8.count <= bytes else { break }
        result.append(character); count += 1; usedBytes += text.utf8.count
    }
    return result
}

func chatJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
