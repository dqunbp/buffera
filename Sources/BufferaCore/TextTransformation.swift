import Foundation

public enum TextTransformationError: LocalizedError, Equatable {
    case noText, tooLarge, invalidJSON, jsonTooDeep, invalidURL, signedURL

    public var errorDescription: String? {
        switch self {
        case .noText: return "В записи нет текста для преобразования."
        case .tooLarge: return "Текст или результат больше 2 МБ. Его можно скопировать без оформления."
        case .invalidJSON: return "Не удалось форматировать: текст не является корректным JSON."
        case .jsonTooDeep: return "В JSON больше 128 уровней вложенности. Его можно скопировать без оформления."
        case .invalidURL: return "Нужна одна полная ссылка, начинающаяся с http:// или https://."
        case .signedURL: return "У ссылки есть подпись. Удаление параметров может сделать её недействительной."
        }
    }
}

/// Pure text operations. Clipboard decoding, OCR and writing remain in the app.
public enum TextTransformation: String, CaseIterable {
    case plainText, formatJSON, unwrapLines, removeDuplicateLines, removeTrackingParameters

    public var title: String {
        switch self {
        case .plainText: return "Без оформления"
        case .formatJSON: return "Форматировать JSON"
        case .unwrapLines: return "Убрать переносы строк"
        case .removeDuplicateLines: return "Убрать повторяющиеся строки"
        case .removeTrackingParameters: return "Убрать метки из ссылки"
        }
    }

    public var detail: String {
        switch self {
        case .plainText: return "Обычный текст без шрифтов, цветов и другого оформления."
        case .formatJSON: return "Отступы в JSON; числа, значения и порядок ключей сохраняются."
        case .unwrapLines: return "Соединяет строки пробелами, сохраняя разделение на абзацы."
        case .removeDuplicateLines: return "Оставляет первое появление каждой строки. Регистр, пробелы и пустые строки сохраняются."
        case .removeTrackingParameters: return "Удаляет utm_* и известные рекламные метки, сохраняя остальные параметры ссылки."
        }
    }

    public func apply(to text: String) throws -> String {
        guard !text.isEmpty else { throw TextTransformationError.noText }
        if self == .plainText { return text }
        guard text.utf8.count <= Self.maximumBytes else { throw TextTransformationError.tooLarge }
        let result: String
        switch self {
        case .plainText: result = text
        case .formatJSON:
            var formatter = JSONTextFormatter(text: text, maximumBytes: Self.maximumBytes)
            result = try formatter.format()
        case .unwrapLines:
            let lines = Self.lines(text)
            var output: [String] = [], paragraph: [String] = []
            for line in lines {
                if line.allSatisfy(\.isWhitespace) {
                    if !paragraph.isEmpty { output.append(paragraph.joined(separator: " ")); paragraph.removeAll(keepingCapacity: true) }
                    output.append(line)
                } else {
                    paragraph.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
            if !paragraph.isEmpty { output.append(paragraph.joined(separator: " ")) }
            result = output.joined(separator: "\n")
        case .removeDuplicateLines:
            var seen = Set<Data>()
            result = Self.lines(text).filter { line in
                line.allSatisfy(\.isWhitespace) || seen.insert(Data(line.utf8)).inserted
            }.joined(separator: "\n")
        case .removeTrackingParameters:
            result = try Self.cleanURL(text)
        }
        guard result.utf8.count <= Self.maximumBytes else { throw TextTransformationError.tooLarge }
        return result
    }

    private static let maximumBytes = 2 * 1_024 * 1_024

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }

    private static func cleanURL(_ text: String) throws -> String {
        guard !text.contains(where: \.isWhitespace),
              let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              validPercentEscapes(text) else { throw TextTransformationError.invalidURL }
        // Never rebuild through URLComponents: that can rewrite untouched encoding.
        let fragmentIndex = text.firstIndex(of: "#") ?? text.endIndex
        let baseAndQuery = text[..<fragmentIndex]
        guard let queryIndex = baseAndQuery.firstIndex(of: "?") else { return text }
        let query = baseAndQuery[baseAndQuery.index(after: queryIndex)...]
        let segments = query.split(separator: "&", omittingEmptySubsequences: false)
        func name(_ segment: Substring) -> String {
            let raw = segment.prefix(while: { $0 != "=" })
            return (String(raw).removingPercentEncoding ?? String(raw)).lowercased()
        }
        let trackers: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "yclid", "mc_cid", "mc_eid", "gbraid", "wbraid"]
        let retained = segments.filter { segment in
            let key = name(segment)
            return !key.hasPrefix("utm_") && !trackers.contains(key)
        }
        guard retained.count != segments.count else { return text }
        let signatures: Set<String> = ["signature", "sig", "x-amz-signature", "x-goog-signature", "x-ms-signature", "oauth_signature", "hmac"]
        guard !segments.contains(where: { signatures.contains(name($0)) }) else {
            throw TextTransformationError.signedURL
        }
        let suffix = retained.isEmpty ? "" : "?" + retained.joined(separator: "&")
        return String(baseAndQuery[..<queryIndex]) + suffix + text[fragmentIndex...]
    }

    private static func validPercentEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, bytes[index + 1].isHexDigit, bytes[index + 2].isHexDigit else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
}

/// Validates the JSON grammar while only changing insignificant whitespace.
/// Number and string tokens are copied verbatim, including duplicate object keys.
private struct JSONTextFormatter {
    let input: [UInt8]
    let maximumBytes: Int
    var index = 0
    var output: [UInt8] = []

    init(text: String, maximumBytes: Int) {
        input = Array(text.utf8); self.maximumBytes = maximumBytes
        output.reserveCapacity(min(maximumBytes, input.count + 256))
    }

    mutating func format() throws -> String {
        whitespace()
        try value(depth: 0)
        whitespace()
        guard index == input.count else { throw TextTransformationError.invalidJSON }
        return String(decoding: output, as: UTF8.self)
    }

    private var current: UInt8? { index < input.count ? input[index] : nil }

    private mutating func value(depth: Int) throws {
        whitespace()
        guard let byte = current else { throw TextTransformationError.invalidJSON }
        switch byte {
        case 123: try container(object: true, depth: depth)
        case 91: try container(object: false, depth: depth)
        case 34: try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try number()
        default: throw TextTransformationError.invalidJSON
        }
    }

    private mutating func container(object: Bool, depth: Int) throws {
        guard depth < 128 else { throw TextTransformationError.jsonTooDeep }
        let close: UInt8 = object ? 125 : 93
        try append([input[index]]); index += 1; whitespace()
        if current == close { try append([close]); index += 1; return }
        try newline(depth + 1)
        while true {
            if object {
                guard current == 34 else { throw TextTransformationError.invalidJSON }
                try string(); whitespace()
                guard current == 58 else { throw TextTransformationError.invalidJSON }
                index += 1; try append([58, 32])
            }
            try value(depth: depth + 1); whitespace()
            if current == close {
                index += 1; try newline(depth); try append([close]); return
            }
            guard current == 44 else { throw TextTransformationError.invalidJSON }
            index += 1; whitespace(); try append([44]); try newline(depth + 1)
        }
    }

    private mutating func string() throws {
        let start = index
        index += 1
        while let byte = current {
            if byte == 34 { index += 1; try append(input[start..<index]); return }
            guard byte >= 32 else { throw TextTransformationError.invalidJSON }
            if byte == 92 {
                index += 1
                guard let escape = current else { throw TextTransformationError.invalidJSON }
                if escape == 117 {
                    guard index + 4 < input.count,
                          input[(index + 1)...(index + 4)].allSatisfy(\.isHexDigit) else { throw TextTransformationError.invalidJSON }
                    index += 5
                } else {
                    guard [34, 92, 47, 98, 102, 110, 114, 116].contains(escape) else { throw TextTransformationError.invalidJSON }
                    index += 1
                }
            } else { index += 1 }
        }
        throw TextTransformationError.invalidJSON
    }

    private mutating func number() throws {
        let start = index
        if current == 45 { index += 1 }
        if current == 48 { index += 1 }
        else {
            guard let byte = current, (49...57).contains(byte) else { throw TextTransformationError.invalidJSON }
            digits()
        }
        if current == 46 { index += 1; try requiredDigits() }
        if current == 101 || current == 69 {
            index += 1
            if current == 43 || current == 45 { index += 1 }
            try requiredDigits()
        }
        try append(input[start..<index])
    }

    private mutating func requiredDigits() throws {
        guard let byte = current, (48...57).contains(byte) else { throw TextTransformationError.invalidJSON }
        digits()
    }

    private mutating func digits() {
        while let byte = current, (48...57).contains(byte) { index += 1 }
    }

    private mutating func literal(_ value: String) throws {
        let bytes = Array(value.utf8)
        guard index + bytes.count <= input.count,
              input[index..<(index + bytes.count)].elementsEqual(bytes) else { throw TextTransformationError.invalidJSON }
        index += bytes.count; try append(bytes)
    }

    private mutating func whitespace() {
        while let byte = current, [9, 10, 13, 32].contains(byte) { index += 1 }
    }

    private mutating func newline(_ depth: Int) throws {
        try append([10]); try append(repeatElement(UInt8(32), count: depth * 2))
    }

    private mutating func append<S: Collection>(_ bytes: S) throws where S.Element == UInt8 {
        guard bytes.count <= maximumBytes - output.count else { throw TextTransformationError.tooLarge }
        output.append(contentsOf: bytes)
    }
}

private extension UInt8 {
    var isHexDigit: Bool { (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self) }
}
