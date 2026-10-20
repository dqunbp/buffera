import BufferaLocalization
import AppKit
import BufferaCore

enum CopyTransformError: LocalizedError {
    case unavailable, noText, unreadableText, noImageText, imageTextTooLong, cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.text("Преобразование недоступно для этой записи.")
        case .noText: return L10n.text("В записи нет текста для преобразования.")
        case .unreadableText: return L10n.text("Не удалось прочитать весь текст записи. Исходное содержимое сохранено.")
        case .noImageText: return L10n.text("На изображении не найден текст.")
        case .imageTextTooLong: return L10n.text("Распознанный текст достиг ограничения в 200 000 символов. Нельзя гарантировать копирование целиком.")
        case .cancelled: return L10n.text("Копирование отменено.")
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

    /// Checks the full source using the same transformations as copying. Opening a menu never starts OCR.
    func operations(id: Int64, completion: @escaping (Result<[CopyTransformOperation], Error>) -> Void) {
        storageQueue.async {
            do {
                let candidates = try self.availableOperations(id: id)
                let isImage = candidates.contains(.imageText)
                let cachedText = isImage ? try self.store.imageText(id: id) : nil
                let payload = !isImage && !candidates.isEmpty ? try self.store.payload(id: id) : nil
                self.transformQueue.async {
                    let result = Result {
                        try autoreleasepool {
                            if isImage {
                                guard let cachedText else { return candidates }
                                return (try? Self.validatedImageText(cachedText)) == nil ? [] : candidates
                            }
                            guard let payload else { return [] }
                            let text = try Self.fullText(payload)
                            var lineActions: Set<TextTransformation>?
                            return candidates.filter { operation in
                                guard case .text(let transformation) = operation else { return false }
                                if transformation == .plainText { return true }
                                guard let output = try? transformation.apply(to: text),
                                      !output.utf8.elementsEqual(text.utf8) else { return false }
                                if transformation == .unwrapLines || transformation == .removeDuplicateLines {
                                    let applicable = lineActions ?? Self.applicableLineActions(in: text)
                                    lineActions = applicable
                                    return applicable.contains(transformation)
                                }
                                return true
                            }
                        }
                    }
                    self.storageQueue.async {
                        let checked = result.flatMap { operations in
                            Result {
                                let available = try self.availableOperations(id: id)
                                guard operations.allSatisfy(available.contains) else { throw CopyTransformError.unavailable }
                                return operations
                            }
                        }
                        RunLoop.main.perform(inModes: [.common, .eventTracking]) { completion(checked) }
                    }
                }
            } catch {
                RunLoop.main.perform(inModes: [.common, .eventTracking]) { completion(.failure(error)) }
            }
        }
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
                                return try Self.validatedImageText(text)
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
        guard try availableOperations(id: id).contains(operation) else { throw CopyTransformError.unavailable }
    }

    private func availableOperations(id: Int64) throws -> [CopyTransformOperation] {
        let clip = try store.summary(id: id)
        guard !clip.isConcealed else { throw CopyTransformError.unavailable }
        return CopyTransformOperation.available(for: clip)
    }

    private static func validatedImageText(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CopyTransformError.noImageText
        }
        // The existing OCR index/recognizer caps output at this boundary.
        // A capped result cannot be copied as a complete transformation.
        guard text.count < 200_000 else { throw CopyTransformError.imageTextTooLong }
        return text
    }

    /// Normalizing line endings or trimming one line alone does not make a line action useful.
    private static func applicableLineActions(in text: String) -> Set<TextTransformation> {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var actions = Set<TextTransformation>(), seen = Set<Data>()
        var previousHasText = false
        for line in lines {
            let hasText = !line.allSatisfy(\.isWhitespace)
            if hasText {
                if previousHasText { actions.insert(.unwrapLines) }
                if !seen.insert(Data(line.utf8)).inserted { actions.insert(.removeDuplicateLines) }
            }
            previousHasText = hasText
        }
        return actions
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
