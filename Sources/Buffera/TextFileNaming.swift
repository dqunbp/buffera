import Foundation
import BufferaLocalization

/// Shared by settings and export; naming never changes the file's contents.
enum TextFileNaming: String, CaseIterable {
    case firstLine, dateTime

    static let preferenceKey = "textFileNaming"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .firstLine
    }

    var title: String {
        switch self {
        case .firstLine: return L10n.text("Первая непустая строка")
        case .dateTime: return L10n.text("Дата и время")
        }
    }

    func basename(for text: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        if self == .firstLine {
            var first = ""
            text.enumerateLines { line, stop in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { first = trimmed; stop = true }
            }
            first = first.replacingOccurrences(of: "^#{1,6}(?:\\s+|$)", with: "", options: .regularExpression)
            let unsafe = CharacterSet(charactersIn: "/\\:\"<>|?*").union(.controlCharacters)
            let cleaned = first.unicodeScalars.map { unsafe.contains($0) ? " " : String($0) }.joined()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // Both graphemes and bytes are bounded: emoji may contain many scalars.
            var name = ""
            for character in cleaned.prefix(60) {
                guard name.utf8.count + String(character).utf8.count <= 180 else { break }
                name.append(character)
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if !name.isEmpty { return name }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return L10n.text("Заметка") + "-" + formatter.string(from: date)
    }
}
