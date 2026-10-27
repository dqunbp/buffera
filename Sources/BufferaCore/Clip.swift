import BufferaLocalization
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

public enum ClipKind: String, CaseIterable, Codable, Sendable {
    case text, link, image, file, other
    public var label: String {
        switch self {
        case .text: return L10n.text("Текст")
        case .link: return L10n.text("Ссылка")
        case .image: return L10n.text("Картинка")
        case .file: return L10n.text("Файлы")
        case .other: return L10n.text("Данные")
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

public struct ClipSummary: Identifiable, Sendable {
    public let id: Int64
    public let date: Date
    public let kind: ClipKind
    public let title: String
    public let text: String
    public let source: String
    public let byteCount: Int
    public let isConcealed: Bool
    public let isFavorite: Bool
    public let isRemote: Bool
    /// User-written, unencrypted description; never part of the clipboard payload.
    public let label: String

    /// Translate generated labels only; user content and persisted titles stay intact.
    public var displayTitle: String {
        if isConcealed { return L10n.text("Скрытая запись") }
        if kind == .image && title == "Картинка" { return kind.label }
        if kind == .other && title.hasPrefix("Данные: ") {
            let format = String(title.dropFirst("Данные: ".count))
            let name = format == "неизвестный формат" ? L10n.text("неизвестный формат") : format
            return L10n.text("Данные: \(name)")
        }
        return title
    }

    public init(id: Int64, date: Date, kind: ClipKind, title: String, text: String,
                source: String, byteCount: Int, isConcealed: Bool = false, isFavorite: Bool = false,
                isRemote: Bool = false, label: String = "") {
        self.id = id; self.date = date; self.kind = kind; self.title = title; self.text = text
        self.source = source; self.byteCount = byteCount; self.isConcealed = isConcealed
        self.isFavorite = isFavorite
        self.isRemote = isRemote
        self.label = label
    }
}

public struct SearchFilter: Sendable {
    public var query = ""
    public var kind: ClipKind?
    public var source: String?
    public var favoritesOnly = false
    public var remoteOnly = false
    public var concealedOnly = false
    public var excludesConcealed = false
    public var from: Date?
    public var until: Date? // Exclusive upper bound.
    public init() {}
    public static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
    }
}

/// A record read consistently with its text payload or already-completed image OCR.
/// The store operation determines whether concealed content may be loaded.
public struct ClipContent {
    public let summary: ClipSummary
    public let payload: ClipPayload?
    public let imageText: String?

    public init(summary: ClipSummary, payload: ClipPayload?, imageText: String?) {
        self.summary = summary
        self.payload = payload
        self.imageText = imageText
    }
}

public enum HistoryError: LocalizedError {
    case database(String), missing, invalidPayload
    public var errorDescription: String? {
        switch self {
        case .database(let message): return L10n.text("Ошибка истории: \(message)")
        case .missing: return L10n.text("Запись уже отсутствует в истории.")
        case .invalidPayload: return L10n.text("Не удалось прочитать содержимое записи.")
        }
    }
}
