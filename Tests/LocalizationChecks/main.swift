import Foundation
import BufferaLocalization
import BufferaCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}

let activeLanguage = L10n.language
let suite = "Buffera.LocalizationChecks.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
defer { defaults.removePersistentDomain(forName: suite) }
check(LanguagePreference.load(from: defaults) == .system, "First launch must follow the system")
for value: Any in ["hy", "", 12, true, ["ru"]] {
    defaults.set(value, forKey: LanguagePreference.key)
    check(LanguagePreference.load(from: defaults) == .system, "Invalid preference must fall back to system")
}
for preference in LanguagePreference.allCases {
    preference.save(to: defaults)
    check(LanguagePreference.load(from: defaults) == preference, "Selection must persist")
    if preference != .system {
        check(defaults.stringArray(forKey: "AppleLanguages") == [preference.rawValue],
              "Native panels must use the explicitly selected language on relaunch")
    }
}
LanguagePreference.system.save(to: defaults)
let saved = defaults.persistentDomain(forName: suite) ?? [:]
check(saved[LanguagePreference.key] == nil && saved["AppleLanguages"] == nil,
      "System must remove app language overrides while inheriting global languages")
for (languages, expected) in [
    (["ru-RU", "en-US"], "ru"), (["en-GB", "ru"], "en"),
    (["hy-AM", "ru-AM", "en"], "ru"), (["fr-FR", "en"], "fr"),
    (["ru"], "ru"), (["ru_RU"], "ru"), (["hy-AM"], "en"), ([], "en"),
    (["de-AT", "en"], "de"), (["es-MX", "en"], "es"),
    (["pt-BR", "en"], "pt-BR"), (["pt-PT", "en"], "pt-BR"), (["PT_br"], "pt-BR"),
    (["zh-Hans-CN", "en"], "zh-Hans"), (["zh-CN"], "zh-Hans"), (["zh-SG"], "zh-Hans"),
    (["zh"], "zh-Hans"), (["zh-TW", "ja-JP"], "ja"), (["zh-Hant", "fr"], "fr"),
    (["zh-HK"], "en"), (["zh-MO"], "en"), (["ja-JP", "en"], "ja")
] {
    check(LanguagePreference.system.resolved(preferredLanguages: languages) == expected,
          "System language order and fallback: \(languages)")
    for preference in LanguagePreference.allCases where preference != .system {
        check(preference.resolved(preferredLanguages: languages) == preference.rawValue,
              "Explicit language must override system preferences")
    }
}
let settingsTitles = ["en": "Settings", "ru": "Настройки", "es": "Ajustes", "de": "Einstellungen",
                      "fr": "Réglages", "pt-BR": "Ajustes", "zh-Hans": "设置", "ja": "設定"]
check(Set(settingsTitles.keys) == Set(LanguagePreference.supportedLanguages), "Every language needs a lookup fixture")
for (language, title) in settingsTitles {
    check(L10n.text("Настройки", language: language) == title, "\(language) resource lookup")
}
let searchStatuses = [
    "en": ("Searching by meaning…", "Finding text matches…"),
    "ru": ("Ищу смыслы…", "Ищу совпадения…"),
    "es": ("Buscando por significado…", "Buscando coincidencias…"),
    "de": ("Suche nach Bedeutung…", "Suche nach Texttreffern…"),
    "fr": ("Recherche par sens…", "Recherche de correspondances…"),
    "pt-BR": ("Buscando por significado…", "Buscando correspondências…"),
    "zh-Hans": ("正在按含义搜索…", "正在查找文字匹配…"),
    "ja": ("意味で検索中…", "一致するテキストを検索中…")
]
check(Set(searchStatuses.keys) == Set(LanguagePreference.supportedLanguages),
      "Every language needs semantic and literal search statuses")
for (language, statuses) in searchStatuses {
    check(L10n.text("Ищу смыслы…", language: language) == statuses.0,
          "\(language) semantic search status")
    check(L10n.text("Ищу совпадения…", language: language) == statuses.1,
          "\(language) literal search status")
}
check(L10n.text("Настройки", language: "hy") == "Settings", "Unsupported language uses English")
check(L10n.text("Настройки", language: "de-AT") == "Einstellungen", "Regional resource lookup")
let expectedLanguageCode = ["pt-BR": "pt", "zh-Hans": "zh"][activeLanguage] ?? activeLanguage
check(L10n.locale.language.languageCode?.identifier == expectedLanguageCode,
      "Number/date locale must retain the interface language")
if activeLanguage == "zh-Hans" {
    check(L10n.locale.language.script?.identifier == "Hans", "Date locale must retain Simplified Chinese script")
}
if let region = Locale.current.region {
    check(L10n.locale.region == region, "Number/date locale must retain the user's region")
}
check(L10n.text("Объектов: \(3)", language: "en") == "Items: 3", "English multi-item drag preview")
check(L10n.text("Объектов: \(3)", language: "ru") == "Объектов: 3", "Russian multi-item drag preview")
check(L10n.text("Настройки \( "Buffera" )", language: "en") == "Buffera Settings",
      "Translations can move interpolation before the text")
let untrusted = "%1$@ %@ 100% \\n Русский"
check(L10n.text("Не удалось скопировать: \(untrusted)", language: "en") == "Could not copy: \(untrusted)",
      "Interpolation must not interpret percent signs or translate argument content")
check(L10n.text("Скачивается модель \("Test") · \(42)%. После проверки можно будет задать вопрос.", language: "en")
      == "Downloading Test · 42%. You can ask a question after verification.", "Literal percentages survive formatting")
check(L10n.text("Missing key 100%", language: "en") == "Missing key 100%", "Missing keys have a readable fallback")
check(L10n.diagnostic("Model file not found.") == L10n.text("Файл модели не найден."),
      "Known diagnostics saved in another language use the current translation")
check(L10n.diagnostic("Unknown SDK detail: %@ 100%") == "Unknown SDK detail: %@ 100%",
      "Unknown runtime details remain literal")

// Keep stored labels and the search index independent of interface language.
check(HistoryStore.concealedTitle == "Скрытая запись", "Storage sentinel stays stable")
let sample = ClipSummary(id: 1, date: Date(), kind: .text, title: "Картинка", text: "Картинка",
                         source: "", byteCount: 1, isConcealed: false, isFavorite: false)
check(sample.displayTitle == "Картинка", "User text must never be translated")
let image = ClipSummary(id: 2, date: Date(), kind: .image, title: "Картинка", text: "",
                        source: "", byteCount: 1, isConcealed: false, isFavorite: false)
check(image.displayTitle == L10n.text("Картинка") && image.title == "Картинка",
      "Generated image labels translate without mutating stored metadata")

// Inspect every catalog entry, not just the happy-path UI labels.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/BufferaLocalization/Resources")
func catalog(_ language: String) throws -> [String: String] {
    let data = try Data(contentsOf: root.appendingPathComponent("\(language).lproj/Localizable.strings"))
    return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
}
let en = try catalog("en")
let directories = try FileManager.default.contentsOfDirectory(atPath: root.path)
    .filter { $0.hasSuffix(".lproj") }.map { String($0.dropLast(6)) }
check(Set(directories) == Set(LanguagePreference.supportedLanguages), "Catalogs and selectable languages must agree")
let placeholders = try NSRegularExpression(pattern: #"%\d+\$@"#)
func arguments(_ value: String) -> [String] {
    placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
        .map { (value as NSString).substring(with: $0.range) }.sorted()
}
for language in LanguagePreference.supportedLanguages {
    let translations = try catalog(language)
    check(Set(translations.keys) == Set(en.keys), "\(language) must cover all English keys")
    check(L10n.diagnostic(translations["Файл модели не найден."]!) == L10n.text("Файл модели не найден."),
          "Saved \(language) diagnostics must translate into the active language")
    for (key, value) in translations {
        check(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(language) translation: \(key)")
        check(arguments(key) == arguments(value), "\(language) interpolation mismatch for \(key)")
        for format in [key, value] {
            let literals = placeholders.stringByReplacingMatches(in: format,
                range: NSRange(format.startIndex..., in: format), withTemplate: "")
            check(!literals.replacingOccurrences(of: "%%", with: "").contains("%"),
                  "\(language) unescaped or unsupported format specifier for \(key)")
        }
        if language != "ru" {
            check(value.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil,
                  "Untranslated Russian in \(language): \(key)")
        }
    }
}
print("PASS \(checks) localization checks; \(en.count) translated messages; active language: \(activeLanguage)")
