import Foundation
import CryptoKit

public struct Representation: Codable, Equatable {
    public let type: String
    public let data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public struct ClipPayload: Codable, Equatable {
    public let items: [[Representation]]
    public init(items: [[Representation]]) { self.items = items }
    public var byteCount: Int { items.flatMap { $0 }.reduce(0) { $0 + $1.data.count } }
    public var fingerprint: String {
        var hash = SHA256()
        // Length prefixes distinguish item boundaries and ambiguous concatenations.
        func feed(_ data: Data) {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        for item in items {
            feed(Data("item".utf8))
            for rep in item.sorted(by: { $0.type < $1.type }) {
                feed(Data(rep.type.utf8)); feed(rep.data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ClipKind: String, CaseIterable, Codable {
    case text, link, image, file, other
    public var label: String {
        switch self {
        case .text: return "Текст"
        case .link: return "Ссылка"
        case .image: return "Картинка"
        case .file: return "Файлы"
        case .other: return "Данные"
        }
    }
    public var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc.on.doc"
        case .other: return "square.on.square"
        }
    }
}

public struct ClipSummary: Identifiable {
    public let id: Int64
    public let date: Date
    public let kind: ClipKind
    public let title: String
    public let text: String
    public let source: String
    public let byteCount: Int
    public let isConcealed: Bool

    public init(id: Int64, date: Date, kind: ClipKind, title: String, text: String,
                source: String, byteCount: Int, isConcealed: Bool = false) {
        self.id = id; self.date = date; self.kind = kind; self.title = title; self.text = text
        self.source = source; self.byteCount = byteCount; self.isConcealed = isConcealed
    }
}

public struct SearchFilter {
    public var query = ""
    public var kind: ClipKind?
    public var source: String?
    public var from: Date?
    public var until: Date? // Exclusive upper bound.
    public init() {}
    public static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }
}

public enum HistoryError: LocalizedError {
    case database(String), missing, invalidPayload
    public var errorDescription: String? {
        switch self {
        case .database(let message): return "Ошибка истории: \(message)"
        case .missing: return "Запись уже отсутствует в истории."
        case .invalidPayload: return "Не удалось прочитать содержимое записи."
        }
    }
}
