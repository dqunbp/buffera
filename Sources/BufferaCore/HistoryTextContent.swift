import Foundation

/// The same text projection is used by local chat and external agents.
/// This never reads files named in the clipboard and never starts OCR.
public struct HistoryTextContent: Sendable {
    public enum Kind: String, Sendable {
        case text, cachedOCR, filePaths, unavailableOCR, unsupported
    }
    public let text: String
    public let kind: Kind
    public let isComplete: Bool
    public let note: String?

    public static func decode(_ content: ClipContent) throws -> HistoryTextContent {
        func payload() throws -> ClipPayload {
            guard let payload = content.payload, !payload.items.isEmpty,
                  payload.items.allSatisfy({ !$0.isEmpty }) else { throw HistoryError.invalidPayload }
            return payload
        }
        switch content.summary.kind {
        case .text, .link:
            let texts = try payload().items.map { item in
                guard let text = ClipboardText.decode(item) else { throw HistoryError.invalidPayload }
                return text
            }
            return Self(text: texts.joined(separator: "\n"), kind: .text, isComplete: true, note: nil)
        case .file:
            let paths = try payload().items.map { item in
                guard let representation = item.first(where: { $0.type == "public.file-url" }),
                      let rawURL = String(data: representation.data, encoding: .utf8),
                      let url = URL(string: rawURL), url.isFileURL, !url.path.isEmpty else {
                    throw HistoryError.invalidPayload
                }
                return url.path
            }
            return Self(text: paths.joined(separator: "\n"), kind: .filePaths, isComplete: true,
                        note: "Только пути из буфера обмена. Содержимое файлов не читается.")
        case .image:
            guard let text = content.imageText else {
                return Self(text: "", kind: .unavailableOCR, isComplete: false,
                            note: "Готового OCR нет. MCP не запускает распознавание и не передаёт изображение.")
            }
            let complete = text.count < 200_000
            return Self(text: text, kind: .cachedOCR, isComplete: complete,
                        note: complete ? "Сохранённый результат OCR."
                            : "Сохранённый OCR достиг лимита 200000 символов и может быть обрезан.")
        case .other:
            return Self(text: "", kind: .unsupported, isComplete: false,
                        note: "Для этого типа записи доступны только метаданные.")
        }
    }
}
