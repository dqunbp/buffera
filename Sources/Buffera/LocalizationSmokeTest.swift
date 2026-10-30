import AppKit
import BufferaCore
import BufferaLocalization

/// Real settings controls with isolated preferences and no clipboard/history access.
func runLocalizationSmokeTest() throws {
    let activeLanguage = L10n.language
    NSApplication.shared.setActivationPolicy(.prohibited)
    let originalAppearance = NSApp.appearance
    defer { NSApp.appearance = originalAppearance }
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
                       themeDefaults: defaults,
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
    InterfaceTheme.system.apply()
    content.layoutSubtreeIfNeeded()
    guard let language = descendants(content).first(where: {
        $0.identifier?.rawValue == "settings.language"
    }) as? NSPopUpButton else { throw HistoryError.database("Language selector missing") }
    guard let notice = descendants(content).first(where: { $0.identifier?.rawValue == "settings.restartNotice" }),
          let restart = descendants(content).first(where: { $0.identifier?.rawValue == "settings.restart" }) as? NSButton else {
        throw HistoryError.database("Restart controls missing")
    }
    guard let theme = descendants(content).first(where: {
        $0.identifier?.rawValue == "settings.theme"
    }) as? NSPopUpButton else { throw HistoryError.database("Theme selector missing") }
    let expectedThemes = [L10n.text("Системная"), L10n.text("Светлая"), L10n.text("Тёмная")]
    try check(theme.itemTitles == expectedThemes && theme.indexOfSelectedItem == 0,
              "Theme options must be translated and initially follow the system")
    for invalid: Any in ["unknown", 7, true, ["dark"]] {
        defaults.set(invalid, forKey: InterfaceTheme.key)
        try check(InterfaceTheme.load(from: defaults) == .system, "Invalid theme must fall back to system")
    }
    let expectedAppearances: [NSAppearance.Name?] = [nil, .aqua, .darkAqua]
    for (index, preference) in InterfaceTheme.allCases.enumerated() {
        theme.selectItem(at: index)
        try check(theme.sendAction(theme.action, to: theme.target), "Theme action disconnected")
        try check(InterfaceTheme.load(from: defaults) == preference, "Theme choice did not persist")
        try check(NSApp.appearance?.name == expectedAppearances[index], "Theme must apply immediately to the application")
        try check(notice.isHidden, "Changing theme must not request a restart")
        let reopened = makeSettings()
        let selected = descendants(reopened.window!.contentView!).first { $0.identifier?.rawValue == "settings.theme" } as? NSPopUpButton
        try check(selected?.indexOfSelectedItem == index, "Reopened settings lost the selected theme")
        if let expected = expectedAppearances[index] {
            try check(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected &&
                      reopened.window!.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                      "Existing and new windows must inherit the selected application theme")
        }
        NSApp.appearance = nil
        InterfaceTheme.load(from: defaults).apply()
        try check(NSApp.appearance?.name == expectedAppearances[index], "Saved theme must reapply at launch")
    }
    theme.selectItem(at: 0)
    _ = theme.sendAction(theme.action, to: theme.target)
    try check(defaults.object(forKey: InterfaceTheme.key) == nil && NSApp.appearance == nil,
              "System theme must remove the app override")
    try check(HistoryLimits.load(from: defaults) == customLimits,
              "Changing theme must preserve unrelated history settings")
    var restartRequests = 0
    controller.onRestart = { restartRequests += 1 }
    try check(notice.isHidden, "Unchanged language must not request restart")
    try check(language.itemTitles == LanguagePreference.allCases.map(\.title), "Language options are incomplete")
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
    let expectedTitle = L10n.text("Настройки \("Buffera")")
    try check(window.title == expectedTitle, "Window title is not translated")
    try check(!window.isVisible, "Smoke check must not open a window")
    for view in descendants(content) where !view.isHiddenOrHasHiddenAncestor && view is NSControl {
        let frame = content.convert(view.bounds, from: view)
        try check(content.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Settings control lies outside the window")
    }
    guard let tabs = descendants(content).compactMap({ $0 as? NSSegmentedControl }).first else {
        throw HistoryError.database("Settings tabs missing")
    }
    try check(content.bounds.contains(content.convert(tabs.bounds, from: tabs)), "Settings tabs exceed the window width")
    guard let setup = descendants(content).first(where: { $0.identifier?.rawValue == "settings.showSetup" }) as? NSButton else {
        throw HistoryError.database("Appearance page is missing the setup action")
    }
    var setupRequests = 0
    controller.onShowSetup = { setupRequests += 1 }
    setup.performClick(nil)
    try check(setupRequests == 1, "Setup action is disconnected or duplicated")
    for index in 1..<tabs.segmentCount {
        tabs.selectedSegment = index
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        try check(!descendants(content).contains(where: { $0 === setup }),
                  "Setup action must only appear on the appearance page")
    }
    tabs.selectedSegment = 0
    _ = tabs.sendAction(tabs.action, to: tabs.target)
    content.layoutSubtreeIfNeeded()
    try check(descendants(content).contains(where: { $0 === setup }), "Returning to appearance lost the setup action")
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/buffera-settings-appearance-\(activeLanguage).png"))
    }
    tabs.selectedSegment = 1
    _ = tabs.sendAction(tabs.action, to: tabs.target)
    func snapshot(_ name: String) throws {
        content.layoutSubtreeIfNeeded()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/buffera-settings-\(name)-\(activeLanguage).png"))
        }
    }
    try check(tabs.segmentCount == 6 && !(0..<tabs.segmentCount).contains { tabs.label(forSegment: $0) == L10n.text("Копирование") },
              "File naming must not have a separate settings tab")
    try check(!descendants(content).contains { $0.identifier?.rawValue == "settings.textFileNaming" },
              "File export must not appear among history settings")
    for (section, controls) in [
        ("storage", ["countLimit", "byteLimit", "revealData"]),
        ("secrets", ["secretHistoryMode"]),
        ("reopening", ["historyReset.enabled", "historyReset.minutes"])
    ] {
        guard let group = descendants(content).first(where: { $0.identifier?.rawValue == "settings.history.\(section)" }) else {
            throw HistoryError.database("History settings group missing: \(section)")
        }
        for control in controls {
            try check(descendants(group).contains { $0.identifier?.rawValue == "settings.\(control)" },
                      "History control is outside its semantic group: \(control)")
        }
    }
    var revealRequests = 0
    controller.onRevealData = { revealRequests += 1 }
    (descendants(content).first { $0.identifier?.rawValue == "settings.revealData" } as? NSButton)?.performClick(nil)
    try check(revealRequests == 1, "Data folder action must stay connected after regrouping")
    try snapshot("history")
    guard let resetEnabled = descendants(content).first(where: { $0.identifier?.rawValue == "settings.historyReset.enabled" }) as? NSButton,
          let resetMinutes = descendants(content).first(where: { $0.identifier?.rawValue == "settings.historyReset.minutes" }) as? NSTextField,
          let resetStepper = descendants(content).first(where: { $0.identifier?.rawValue == "settings.historyReset.stepper" }) as? NSStepper else {
        throw HistoryError.database("History reset controls missing")
    }
    try check(resetEnabled.state == .on && resetMinutes.integerValue == 1 && resetMinutes.isEnabled,
              "History reset defaults must be visible in settings")
    resetStepper.integerValue = 7
    _ = resetStepper.sendAction(resetStepper.action, to: resetStepper.target)
    try check(HistoryResetPreferences.load(from: defaults).minutes == 7 && resetMinutes.integerValue == 7,
              "Reset stepper must save its duration immediately")
    resetMinutes.integerValue = 12
    resetMinutes.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: resetMinutes))
    try check(HistoryResetPreferences.load(from: defaults).minutes == 12 && resetStepper.integerValue == 12,
              "Typed reset duration must save and synchronize its stepper")
    resetEnabled.performClick(nil)
    try check(!HistoryResetPreferences.load(from: defaults).isEnabled && !resetMinutes.isEnabled && !resetStepper.isEnabled,
              "Disabling reset must persist and disable the duration controls")
    let resetReopened = makeSettings()
    let resetRoot = resetReopened.window!.contentView!
    let resetTabs = descendants(resetRoot).compactMap { $0 as? NSSegmentedControl }.first!
    resetTabs.selectedSegment = 1
    _ = resetTabs.sendAction(resetTabs.action, to: resetTabs.target)
    let restoredReset = descendants(resetRoot).first { $0.identifier?.rawValue == "settings.historyReset.enabled" } as? NSButton
    let restoredMinutes = descendants(resetRoot).first { $0.identifier?.rawValue == "settings.historyReset.minutes" } as? NSTextField
    try check(restoredReset?.state == .off && restoredMinutes?.integerValue == 12 && restoredMinutes?.isEnabled == false,
              "Reopened settings must retain both reset preferences")
    resetEnabled.performClick(nil)
    try check(resetMinutes.isEnabled && HistoryResetPreferences.load(from: defaults).minutes == 12,
              "Re-enabling reset must preserve the custom duration")
    var copyRequests = 0
    func namingMenu() throws -> NSMenu {
        let menu = CopyTransformMenu(operations: [.textFile(.txt), .textFile(.md)], defaults: defaults) { _ in copyRequests += 1 }
        guard let item = menu.items.last, item.title == L10n.text("Имя текстового файла"), item.submenu != nil else {
            throw HistoryError.database("Copy menu is missing its translated file naming setting")
        }
        // Retain the parent: AppKit menu item targets and supermenu links are weak.
        return menu
    }
    let naming = try namingMenu()
    let choices = naming.items.last!.submenu!
    try check(choices.items.map(\.title) == [L10n.text("Первая непустая строка"), L10n.text("Дата и время")]
              && choices.items.first?.state == .on, "File naming choices must be translated and default to first line")
    for (index, mode) in TextFileNaming.allCases.enumerated() {
        choices.performActionForItem(at: index)
        try check(TextFileNaming.load(from: defaults) == mode && copyRequests == 0,
                  "Choosing the filename style must persist without copying an entry")
        let reopened = try namingMenu()
        try check(reopened.items.last!.submenu!.items[index].state == .on,
                  "Reopening the copy menu must retain the selected filename style")
    }
    guard let secrets = descendants(content).first(where: { $0.identifier?.rawValue == "settings.secretHistoryMode" }) as? NSPopUpButton else {
        throw HistoryError.database("Secret history selector missing")
    }
    let secretTitles = [L10n.text("Не сохранять секреты"), L10n.text("Сохранять секреты зашифрованными")]
    try check(secrets.itemTitles == secretTitles && secrets.indexOfSelectedItem == 0,
              "Secret storage defaults or translations are incorrect")
    guard let secretStatus = descendants(content).first(where: { $0.identifier?.rawValue == "settings.secretHistoryStatus" }) as? NSTextField else {
        throw HistoryError.database("Secret history status missing")
    }
    try check(secretStatus.isHidden, "Empty secret status must not leave a gap in the history page")
    var finishSecretChange: ((Result<Void, Error>) -> Void)?
    controller.onSecretHistoryChange = { _, completion in finishSecretChange = completion }
    secrets.selectItem(at: 1)
    try check(secrets.sendAction(secrets.action, to: secrets.target), "Secret setting is disconnected")
    try check(!secrets.isEnabled && SecretHistoryMode.load(from: defaults) == .skip,
              "Secret setting persisted before key preparation completed")
    try check(!secretStatus.isHidden && !secretStatus.stringValue.isEmpty, "Pending secret change must be visible")
    finishSecretChange?(.failure(SecretStorageError.keyUnavailable))
    try check(!secretStatus.isHidden && !secretStatus.stringValue.isEmpty, "Key preparation errors must remain visible")
    try check(secrets.isEnabled && secrets.indexOfSelectedItem == 0 && SecretHistoryMode.load(from: defaults) == .skip,
              "Failed key preparation changed the selected policy")
    secrets.selectItem(at: 1)
    _ = secrets.sendAction(secrets.action, to: secrets.target)
    finishSecretChange?(.success(()))
    try check(secrets.indexOfSelectedItem == 1 && SecretHistoryMode.load(from: defaults) == .encrypted,
              "Successful secret setting did not persist")
    try check(secretStatus.isHidden, "Successful secret change must remove the empty status row")
    let secretReopened = makeSettings()
    let secretTabs = descendants(secretReopened.window!.contentView!).compactMap { $0 as? NSSegmentedControl }.first!
    secretTabs.selectedSegment = 1
    _ = secretTabs.sendAction(secretTabs.action, to: secretTabs.target)
    let restoredSecrets = descendants(secretReopened.window!.contentView!).first { $0.identifier?.rawValue == "settings.secretHistoryMode" } as? NSPopUpButton
    try check(restoredSecrets?.indexOfSelectedItem == 1, "Reopened settings lost secret storage mode")
    secrets.selectItem(at: 0)
    _ = secrets.sendAction(secrets.action, to: secrets.target)
    finishSecretChange?(.success(()))
    try check(SecretHistoryMode.load(from: defaults) == .skip, "Disabling secret capture did not persist")
    try check(HistoryLimits.load(from: defaults) == customLimits, "Secret setting changed ordinary history limits")
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
        // The history page scrolls as settings grow; offscreen controls must
        // remain within the scrollable document and be reachable by scrolling.
        let container = view.enclosingScrollView?.documentView ?? content
        // Native buttons include shadow margins outside their layout rectangle.
        let frame = container.convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
        // Native text fields may extend two points beyond their alignment rectangle.
        try check(container.bounds.insetBy(dx: -3, dy: -3).contains(frame), "History control \(view.identifier?.rawValue ?? String(describing: type(of: view))) \(frame) lies outside \(container.bounds)")
    }
    print("PASS: \(activeLanguage) settings theme and language selection, persistence, restart action, history groups, file naming menu, size slider and layout")
}
