import AppKit
import BufferaCore
import BufferaLocalization

/// Real settings controls with isolated preferences and no clipboard/history access.
func runLocalizationSmokeTest() throws {
    let activeLanguage = L10n.language
    NSApplication.shared.setActivationPolicy(.prohibited)
    let suite = "Buffera.LocalizationUI.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    func makeSettings() -> SettingsWindow {
        SettingsWindow(mcpAccess: MCPAccess(directory: directory), languageDefaults: defaults, frameAutosaveName: nil)
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HistoryError.database(message) }
    }
    let controller = makeSettings()
    guard let window = controller.window, let content = window.contentView else {
        throw HistoryError.database("Settings window missing")
    }
    window.appearance = NSAppearance(named: .aqua)
    content.layoutSubtreeIfNeeded()
    guard let language = descendants(content).first(where: {
        $0.identifier?.rawValue == "settings.language"
    }) as? NSPopUpButton else { throw HistoryError.database("Language selector missing") }
    let expectedSystem = activeLanguage == "ru" ? "Системный" : "System"
    try check(language.itemTitles == [expectedSystem, "Русский", "English"], "Language options are incomplete")
    try check(language.indexOfSelectedItem == 0, "Fresh settings must select System")
    let initialTitle = window.title
    for (index, preference) in LanguagePreference.allCases.enumerated() {
        language.selectItem(at: index)
        try check(language.sendAction(language.action, to: language.target), "Language selection action disconnected")
        try check(LanguagePreference.load(from: defaults) == preference, "Language selection did not persist")
        try check(window.title == initialTitle && L10n.language == activeLanguage,
                  "A pending language change must not mix languages in the running app")
        let reopened = makeSettings()
        guard let root = reopened.window?.contentView,
              let selected = descendants(root).first(where: {
                  $0.identifier?.rawValue == "settings.language"
              }) as? NSPopUpButton else { throw HistoryError.database("Reopened selector missing") }
        try check(selected.indexOfSelectedItem == index, "Reopened settings lost the selected language")
    }
    language.selectItem(at: 0)
    _ = language.sendAction(language.action, to: language.target)
    let saved = defaults.persistentDomain(forName: suite) ?? [:]
    try check(saved[LanguagePreference.key] == nil && saved["AppleLanguages"] == nil,
              "Returning to System did not clear language overrides")
    let expectedTitle = activeLanguage == "ru" ? "Настройки Buffera" : "Buffera Settings"
    try check(window.title == expectedTitle, "Window title is not translated")
    try check(!window.isVisible, "Smoke check must not open a window")
    for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor && view is NSControl {
        let frame = content.convert(view.bounds, from: view)
        try check(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Settings control lies outside the window")
    }
    print("PASS: \(activeLanguage) settings language selection, persistence, restart boundary and layout")
}
