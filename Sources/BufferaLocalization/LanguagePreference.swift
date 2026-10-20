import Foundation

public enum LanguagePreference: String, CaseIterable, Sendable {
    case system, russian = "ru", english = "en"

    public static let key = "interfaceLanguage"

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
            if let language = Locale(identifier: identifier).language.languageCode?.identifier,
               language == "ru" || language == "en" { return language }
        }
        return "en"
    }

    public var title: String {
        switch self {
        case .system: return L10n.text("Системный")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }
}
