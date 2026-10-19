import AppKit
import BufferaCore

enum CopyTransformError: LocalizedError {
    case unavailable, noText, unreadableText, noImageText, imageTextTooLong, cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Преобразование недоступно для этой записи."
        case .noText: return "В записи нет текста для преобразования."
        case .unreadableText: return "Не удалось прочитать весь текст записи. Исходное содержимое сохранено."
        case .noImageText: return "На изображении не найден текст."
        case .imageTextTooLong: return "Распознанный текст достиг ограничения в 200 000 символов. Нельзя гарантировать копирование целиком."
        case .cancelled: return "Копирование отменено."
        }
    }
}

/// Reads SQLite on the existing history queue; decoding and transformations never block it.
final class CopyTransformService {
    private let store: HistoryStore
    private let storageQueue: DispatchQueue
    private let transformQueue = DispatchQueue(label: "app.buffera.copy-transform", qos: .userInitiated)
    private let recognize: (ClipPayload) throws -> String

    init(store: HistoryStore, storageQueue: DispatchQueue,
         recognize: @escaping (ClipPayload) throws -> String = ImageTextRecognizer.recognize) {
        self.store = store
        self.storageQueue = storageQueue
        self.recognize = recognize
    }

    /// The owner guards its presentation epoch. Every request delivers once, including failures.
    func transform(id: Int64, operation: CopyTransformOperation,
                   completion: @escaping (Result<String, Error>) -> Void) {
        storageQueue.async {
            do {
                try self.validate(id: id, operation: operation)
                let cachedText = operation == .imageText ? try self.store.imageText(id: id) : nil
                let payload = cachedText == nil ? try self.store.payload(id: id) : nil
                self.transformQueue.async {
                    let result = Result {
                        try autoreleasepool {
                            switch operation {
                            case .text(let transformation):
                                guard let payload else { throw HistoryError.invalidPayload }
                                let text = try Self.fullText(payload)
                                return try transformation.apply(to: text)
                            case .imageText:
                                let text: String
                                if let cachedText { text = cachedText }
                                else if let payload { text = try self.recognize(payload) }
                                else { throw HistoryError.invalidPayload }
                                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                    throw CopyTransformError.noImageText
                                }
                                // The existing OCR index/recognizer caps output at this boundary.
                                // A capped result cannot be presented as a complete transformation.
                                guard text.count < 200_000 else { throw CopyTransformError.imageTextTooLong }
                                return text
                            }
                        }
                    }
                    // Concealment, pruning, or deletion may have happened during expensive work.
                    self.storageQueue.async {
                        let checked = result.flatMap { text in
                            Result { try self.validate(id: id, operation: operation); return text }
                        }
                        DispatchQueue.main.async { completion(checked) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func validate(id: Int64, operation: CopyTransformOperation) throws {
        let clip = try store.summary(id: id)
        guard CopyTransformOperation.available(for: clip).contains(operation) else { throw CopyTransformError.unavailable }
    }

    private static func fullText(_ payload: ClipPayload) throws -> String {
        guard !payload.items.isEmpty else { throw CopyTransformError.noText }
        let parts = try payload.items.map { representations -> String in
            guard let text = ClipboardService.text(in: representations) else { throw CopyTransformError.unreadableText }
            return text
        }
        let text = parts.joined(separator: "\n")
        guard !text.isEmpty else { throw CopyTransformError.noText }
        return text
    }
}
