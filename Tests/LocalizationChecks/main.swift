import Foundation
import BufferaLocalization
import BufferaCore

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}

let suite = "Buffera.LocalizationChecks.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(LanguagePreference.load(from: defaults) == .system, "First launch must follow the system")
for value: Any in ["fr", "", 12, true, ["ru"]] {
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
    (["hy-AM", "ru-AM", "en"], "ru"), (["fr-FR", "en"], "en"),
    (["ru"], "ru"), (["ru_RU"], "ru"), (["hy-AM"], "en"), ([], "en")
] {
    check(LanguagePreference.system.resolved(preferredLanguages: languages) == expected,
          "System language order and fallback: \(languages)")
    check(LanguagePreference.russian.resolved(preferredLanguages: languages) == "ru", "Explicit Russian")
    check(LanguagePreference.english.resolved(preferredLanguages: languages) == "en", "Explicit English")
}
check(L10n.text("Настройки", language: "en") == "Settings", "English resource lookup")
check(L10n.text("Настройки", language: "ru") == "Настройки", "Russian resource lookup")
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
let ru = try catalog("ru"), en = try catalog("en")
check(Set(ru.keys) == Set(en.keys), "Both languages must cover the same keys")
let placeholders = try NSRegularExpression(pattern: #"%\d+\$@"#)
func arguments(_ value: String) -> [String] {
    placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value))
        .map { (value as NSString).substring(with: $0.range) }.sorted()
}
for (key, value) in en {
    check(!value.isEmpty, "Empty English translation")
    check(arguments(key) == arguments(value) && arguments(key) == arguments(ru[key]!),
          "Interpolation mismatch for \(key)")
    for format in [key, value, ru[key]!] {
        let literals = placeholders.stringByReplacingMatches(in: format,
            range: NSRange(format.startIndex..., in: format), withTemplate: "")
        check(!literals.replacingOccurrences(of: "%%", with: "").contains("%"),
              "Unescaped or unsupported format specifier for \(key)")
    }
    check(value.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil,
          "Untranslated Russian in English catalog: \(key)")
}
print("PASS \(checks) localization checks; \(en.count) translated messages; active language: \(L10n.language)")
