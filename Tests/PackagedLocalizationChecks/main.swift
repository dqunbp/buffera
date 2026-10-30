import Foundation
import BufferaLocalization

let expected = ["en": "Settings", "ru": "Настройки", "es": "Ajustes", "de": "Einstellungen",
                "fr": "Réglages", "pt-BR": "Ajustes", "zh-Hans": "设置", "ja": "設定"]
guard Set(expected.keys) == Set(LanguagePreference.supportedLanguages) else {
    fatalError("Packaged check is missing a supported language")
}
for (language, title) in expected {
    guard L10n.text("Настройки", language: language) == title else {
        fatalError("Packaged \(language) translations did not load")
    }
}
print("PASS: all packaged translations with source checkout access denied")
