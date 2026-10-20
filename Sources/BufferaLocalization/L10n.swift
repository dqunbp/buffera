import Foundation

/// A launch uses one immutable language across UI and background operations.
/// Saving a preference takes effect on the next launch.
public enum L10n {
    public static let preference = LanguagePreference.load()
    public static let language = preference.resolved()
    public static let locale = Locale(identifier:
        "\(language)_\(Locale.current.region?.identifier ?? (language == "ru" ? "RU" : "US"))")

    public static func text(_ message: Message) -> String {
        text(message, language: language)
    }

    public static func text(_ message: Message, language: String) -> String {
        let bundle = language == "ru" ? russian : english
        let fallback = english.localizedString(forKey: message.key, value: message.key, table: nil)
        let format = bundle.localizedString(forKey: message.key, value: fallback, table: nil)
        return String(format: format, arguments: message.arguments.map { $0 as NSString })
    }

    /// Translate exact, known runtime diagnostics, including saved errors from
    /// an earlier launch. Unknown technical details pass through unchanged.
    /// Never use this on clipboard content or model answers.
    public static func diagnostic(_ message: String) -> String {
        let key = diagnosticKeys[message] ?? message
        let bundle = language == "ru" ? russian : english
        return bundle.localizedString(forKey: key, value: message, table: nil)
    }

    private static let diagnosticKeys: [String: String] = {
        var keys: [String: String] = [:]
        for bundle in [english, russian] {
            guard let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            else { continue }
            for (key, value) in catalog where !key.contains("%") { keys[value] = key }
        }
        return keys
    }()

    private static let english = localizedBundle("en")
    private static let russian = localizedBundle("ru")

    private static func localizedBundle(_ language: String) -> Bundle {
        guard let url = Bundle.module.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return Bundle.module }
        return bundle
    }

    /// Interpolated values are arguments, never part of the translation key.
    /// Positional placeholders let translators reorder them safely.
    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        public init(stringLiteral value: String) {
            key = value.replacingOccurrences(of: "%", with: "%%")
            arguments = []
        }

        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        public struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []

            public init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }

            public mutating func appendLiteral(_ literal: String) {
                key += literal.replacingOccurrences(of: "%", with: "%%")
            }

            public mutating func appendInterpolation<T>(_ value: T) {
                arguments.append(String(describing: value))
                key += "%\(arguments.count)$@"
            }
        }
    }
}
