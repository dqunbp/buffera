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
    let customLimits = HistoryLimits(maxCount: 42_000, maxBytes: 3_500_000_000)
    customLimits.save(to: defaults)
    func makeSettings() -> SettingsWindow {
        SettingsWindow(mcpAccess: MCPAccess(directory: directory), languageDefaults: defaults, limitsDefaults: defaults,
                       launchLanguage: .system, frameAutosaveName: nil)
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
    guard let notice = descendants(content).first(where: { $0.identifier?.rawValue == "settings.restartNotice" }),
          let restart = descendants(content).first(where: { $0.identifier?.rawValue == "settings.restart" }) as? NSButton else {
        throw HistoryError.database("Restart controls missing")
    }
    var restartRequests = 0
    controller.onRestart = { restartRequests += 1 }
    try check(notice.isHidden, "Unchanged language must not request restart")
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
        try check(notice.isHidden == (preference == .system), "Restart notice does not reflect the pending preference")
        if preference != .system {
            restart.performClick(nil)
            try check(restartRequests == index, "Restart action is disconnected or duplicated")
        }
        content.layoutSubtreeIfNeeded()
        for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor && view is NSControl {
            let frame = content.convert(view.bounds, from: view)
            try check(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Pending restart control lies outside the window")
        }
        let reopened = makeSettings()
        guard let root = reopened.window?.contentView,
              let selected = descendants(root).first(where: {
                  $0.identifier?.rawValue == "settings.language"
              }) as? NSPopUpButton else { throw HistoryError.database("Reopened selector missing") }
        try check(selected.indexOfSelectedItem == index, "Reopened settings lost the selected language")
        let reopenedNotice = descendants(root).first { $0.identifier?.rawValue == "settings.restartNotice" }
        try check(reopenedNotice?.isHidden == (preference == .system), "Reopened settings lost pending restart state")
    }
    language.selectItem(at: 0)
    _ = language.sendAction(language.action, to: language.target)
    let saved = defaults.persistentDomain(forName: suite) ?? [:]
    try check(saved[LanguagePreference.key] == nil && saved["AppleLanguages"] == nil,
              "Returning to System did not clear language overrides")
    try check(notice.isHidden, "Returning to the launch preference must hide restart notice")
    let expectedTitle = activeLanguage == "ru" ? "Настройки Buffera" : "Buffera Settings"
    try check(window.title == expectedTitle, "Window title is not translated")
    try check(!window.isVisible, "Smoke check must not open a window")
    for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor && view is NSControl {
        let frame = content.convert(view.bounds, from: view)
        try check(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Settings control lies outside the window")
    }
    guard let tabs = descendants(content).compactMap({ $0 as? NSSegmentedControl }).first else {
        throw HistoryError.database("Settings tabs missing")
    }
    tabs.selectedSegment = 1
    _ = tabs.sendAction(tabs.action, to: tabs.target)
    content.layoutSubtreeIfNeeded()
    guard let slider = descendants(content).first(where: { $0.identifier?.rawValue == "settings.byteLimit" }) as? NSSlider,
          let count = descendants(content).first(where: { $0.identifier?.rawValue == "settings.countLimit" }) as? NSPopUpButton,
          let value = descendants(content).first(where: { $0.identifier?.rawValue == "settings.byteLimitValue" }) as? NSTextField else {
        throw HistoryError.database("History size controls missing")
    }
    try check(HistoryLimits.load(from: defaults) == customLimits, "Opening settings changed custom limits")
    count.selectItem(at: count.numberOfItems - 1)
    _ = count.sendAction(count.action, to: count.target)
    try check(HistoryLimits.load(from: defaults).maxBytes == customLimits.maxBytes,
              "Changing count rounded the custom byte limit")
    var changes: [HistoryLimits] = []
    controller.onLimitsChange = { changes.append($0) }
    for gigabytes in [1, 7, 20] {
        slider.doubleValue = Double(gigabytes)
        try check(slider.sendAction(slider.action, to: slider.target), "Size slider is disconnected")
        let expected = HistoryLimits(maxCount: 100_000, maxBytes: gigabytes * HistoryLimits.bytesPerGigabyte)
        try check(HistoryLimits.load(from: defaults) == expected && changes.last == expected,
                  "Slider did not persist the size or notify its owner")
        try check(value.stringValue == L10n.text("\(gigabytes) ГБ"), "Size label does not follow the slider")
    }
    let numberOfChanges = changes.count
    _ = slider.sendAction(slider.action, to: slider.target)
    try check(changes.count == numberOfChanges, "Unchanged slider notified twice")
    let reopened = makeSettings()
    let reopenedContent = reopened.window!.contentView!
    let reopenedTabs = descendants(reopenedContent).compactMap { $0 as? NSSegmentedControl }.first!
    reopenedTabs.selectedSegment = 1
    _ = reopenedTabs.sendAction(reopenedTabs.action, to: reopenedTabs.target)
    let reopenedSlider = descendants(reopenedContent).first { $0.identifier?.rawValue == "settings.byteLimit" } as? NSSlider
    try check(reopenedSlider?.doubleValue == 20, "Reopening settings lost the size limit")
    for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor && view is NSControl {
        let frame = content.convert(view.bounds, from: view)
        try check(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "History control lies outside the window")
    }
    print("PASS: \(activeLanguage) settings language selection, persistence, restart action, history size slider and layout")
}
