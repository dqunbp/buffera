import Foundation

/// A launch uses one immutable language across UI and background operations.
/// Saving a preference takes effect on the next launch.
public enum L10n {
    public static let preference = LanguagePreference.load()
    public static let language = preference.resolved()
    public static let locale: Locale = {
        var components = Locale.Components(identifier: language)
        if let region = Locale.current.region { components.region = region }
        return Locale(components: components)
    }()

    public static func text(_ message: Message) -> String {
        text(message, language: language)
    }

    public static func text(_ message: Message, language: String) -> String {
        let bundle = bundle(for: language)
        let fallback = english.localizedString(forKey: message.key, value: message.key, table: nil)
        let format = bundle.localizedString(forKey: message.key, value: fallback, table: nil)
        return String(format: format, arguments: message.arguments.map { $0 as NSString })
    }

    /// Translate exact, known runtime diagnostics, including saved errors from
    /// an earlier launch. Unknown technical details pass through unchanged.
    /// Never use this on clipboard content or model answers.
    public static func diagnostic(_ message: String) -> String {
        let key = diagnosticKeys[message] ?? message
        let bundle = bundle(for: language)
        return bundle.localizedString(forKey: key, value: message, table: nil)
    }

    private static let diagnosticKeys: [String: String] = {
        var keys: [String: String] = [:]
        for language in LanguagePreference.supportedLanguages {
            let bundle = bundle(for: language)
            guard let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            else { continue }
            for (key, value) in catalog where !key.contains("%") { keys[value] = key }
        }
        return keys
    }()

    private static let bundles = Dictionary(uniqueKeysWithValues:
        LanguagePreference.supportedLanguages.map { ($0, localizedBundle($0)) })
    private static var english: Bundle { bundles["en"]! }

    private static func bundle(for language: String) -> Bundle {
        bundles[language] ?? bundles[LanguagePreference.supportedLanguage(for: language) ?? "en"] ?? english
    }

    private static let resources: Bundle = {
        // SwiftPM's generated Bundle.module searches the .app root, then an
        // absolute build path. Our packaged resources live in Contents/Resources.
        // Resolve those first, so installed apps never probe the source checkout.
        let name = "Buffera_BufferaLocalization.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) { return bundle }
        // Also support the bundled MCP executable launched directly from a shell.
        if let executable = Bundle.main.executableURL,
           executable.deletingLastPathComponent().lastPathComponent == "MacOS" {
            let url = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources").appendingPathComponent(name)
            guard let bundle = Bundle(url: url) else {
                fatalError("Missing packaged Buffera localization resources")
            }
            return bundle
        }
        // SwiftPM executables and fixture harnesses still use their adjacent bundle.
        return Bundle.module
    }()

    private static func localizedBundle(_ language: String) -> Bundle {
        // Native SwiftPM lowercases locale folders (pt-br, zh-hans); Xcode's
        // build system preserves BCP-47 casing. Bundle resource lookup is case-sensitive.
        let folder = resources.localizations.first { $0.caseInsensitiveCompare(language) == .orderedSame } ?? language
        guard let url = resources.resourceURL?.appendingPathComponent("\(folder).lproj"),
              let bundle = Bundle(url: url) else { return language == "en" ? resources : localizedBundle("en") }
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
