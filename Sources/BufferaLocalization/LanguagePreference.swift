import Foundation

public enum LanguagePreference: String, CaseIterable, Sendable {
    case system, russian = "ru", english = "en"
    case spanish = "es", german = "de", french = "fr", portugueseBrazil = "pt-BR"
    case simplifiedChinese = "zh-Hans", japanese = "ja"

    public static let key = "interfaceLanguage"
    public static let supportedLanguages = allCases.filter { $0 != .system }.map(\.rawValue)

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    public func save(to defaults: UserDefaults = .standard) {
        if self == .system {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(rawValue, forKey: Self.key)
            // App-scoped only: native panels also use this language on relaunch.
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        // Keep the user's preference order, including regional language variants.
        for identifier in preferredLanguages {
            if let language = Self.supportedLanguage(for: identifier) { return language }
        }
        return "en"
    }

    /// Match regional variants without treating Traditional Chinese as Simplified.
    public static func supportedLanguage(for identifier: String) -> String? {
        let locale = Locale(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
        guard let language = locale.language.languageCode?.identifier.lowercased() else { return nil }
        if language == "pt" { return "pt-BR" }
        if language == "zh" {
            let script = locale.language.script?.identifier
            if script == "Hant" { return nil }
            if script != "Hans", let region = locale.region?.identifier,
               ["TW", "HK", "MO"].contains(region) { return nil }
            return "zh-Hans"
        }
        return supportedLanguages.first { $0 == language }
    }

    public var title: String {
        switch self {
        case .system: return L10n.text("Системный")
        case .russian: return "Русский"
        case .english: return "English"
        case .spanish: return "Español"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .portugueseBrazil: return "Português (Brasil)"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }
}
