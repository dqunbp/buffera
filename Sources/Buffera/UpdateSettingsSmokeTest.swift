import AppKit
import BufferaCore
import BufferaLocalization
import BufferaUpdates

/// Isolated preferences and transport; never reads clipboard/history or opens a browser.
@MainActor func runUpdateSettingsSmokeTest() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let suite = "Buffera.UpdateUI.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let previousAppearance = NSApp.appearance
    NSApp.appearance = NSAppearance(named: .aqua)
    defer { NSApp.appearance = previousAppearance }
    let release = ReleaseUpdate(tag: "v99.0.0")!
    var failure: UpdateCheckFailure?
    let checker = UpdateChecker(installedVersion: AppVersion.version, supportsRelease: true, defaults: defaults,
                                fetch: { if let failure { throw failure }; return release })
    let controller = AppUpdateController(checker: checker)
    defer { controller.stop() }
    var badge: ReleaseUpdate?
    controller.onIndicatorChange = { badge = $0 }
    let settings = SettingsWindow(mcpAccess: MCPAccess(directory: directory), updateSettings: controller.settingsView,
                                  languageDefaults: defaults, limitsDefaults: defaults, themeDefaults: defaults,
                                  shortcutDefaults: defaults, frameAutosaveName: nil)
    let root = settings.window!.contentView!
    func descendants(_ view: NSView) -> [NSView] {
        var children = view.subviews
        if let stack = view as? NSStackView {
            children += stack.arrangedSubviews.filter { candidate in !children.contains { $0 === candidate } }
        }
        return [view] + children.flatMap(descendants)
    }
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw HistoryError.database(message) }
    }
    func control<T: NSView>(_ name: String, _ type: T.Type) throws -> T {
        guard let control = descendants(root).first(where: { $0.identifier?.rawValue == "updates.\(name)" }) as? T
        else { throw HistoryError.database("Missing update control: \(name)") }
        return control
    }
    func waitFor(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try check(predicate(), "Update controller did not finish the fixture request")
    }
    let tabs = descendants(root).compactMap { $0 as? NSSegmentedControl }.first!
    try check(tabs.segmentCount == 6 && tabs.label(forSegment: 5) == (L10n.language == "en" ? "Updates" : "Обновления"),
              "Updates settings tab is missing or untranslated: language=\(L10n.language), labels=\((0..<tabs.segmentCount).map { tabs.label(forSegment: $0) ?? "" })")
    tabs.selectedSegment = 5
    _ = tabs.sendAction(tabs.action, to: tabs.target)
    root.layoutSubtreeIfNeeded()
    let status = try control("status", NSTextField.self)
    let detail = try control("detail", NSTextField.self)
    let checkButton = try control("check", NSButton.self)
    let open = try control("open", NSButton.self)
    let skip = try control("skip", NSButton.self)
    let automatic = try control("automatic", NSButton.self)
    try check(open.isHidden && skip.isHidden && badge == nil, "Unknown version must not offer an update")
    try check(checkButton.title == (L10n.language == "en" ? "Check for Updates…" : "Проверить обновления…"),
              "Update controls must use the selected language")
    controller.start()
    try waitFor { badge == release && !checker.isChecking }
    try check(!open.isHidden && !skip.isHidden && status.stringValue.contains("99.0.0"),
              "New release must appear in settings and on the menu-bar icon")
    skip.performClick(nil)
    try check(badge == nil && !open.isHidden && !skip.isEnabled,
              "Skipping must clear the dot and keep the release accessible")
    automatic.performClick(nil)
    try check(!checker.automaticEnabled, "Automatic preference did not reach the checker")
    failure = .unavailable
    checkButton.performClick(nil)
    try waitFor { detail.stringValue == L10n.text("Проверьте подключение к интернету и повторите попытку позже. Приложение продолжает работать.") }
    try check(!open.isHidden && status.stringValue.contains("99.0.0") && badge == nil,
              "Offline manual check lost a known skipped update")
    controller.settingsView.render(automatic: false, checking: true, release: nil, skipped: false, outcome: nil)
    try check(!checkButton.isEnabled && open.isHidden, "In-flight check must disable duplicate manual requests")
    controller.settingsView.render(automatic: false, checking: false, release: nil, skipped: false, outcome: .upToDate)
    try check(checkButton.isEnabled && status.stringValue == L10n.text("У вас актуальная версия"), "Current-version state missing")
    controller.settingsView.render(automatic: false, checking: false, release: nil, skipped: false, outcome: .noCompatibleRelease)
    try check(status.stringValue == L10n.text("Подходящий релиз не найден"), "Missing release must not claim up to date")
    controller.settingsView.render(automatic: true, checking: false, release: release, skipped: false, outcome: .available(release))
    root.layoutSubtreeIfNeeded()
    for view in descendants(root) where !view.isHiddenOrHasHiddenAncestor && view is NSControl {
        let rect = view.convert(view.bounds, to: root)
        try check(root.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Update settings control overflows window: \(view.identifier?.rawValue ?? "label")")
    }
    for index in 0..<tabs.segmentCount {
        let width = (tabs.label(forSegment: index)! as NSString).size(withAttributes: [.font: tabs.font ?? NSFont.systemFont(ofSize: 13)]).width
        try check(width + 8 <= tabs.width(forSegment: index), "Settings tab title is clipped")
    }
    let plain = BrandIdentity.menuBarIcon()
    let badged = BrandIdentity.menuBarIcon(hasUpdate: true)
    try check(plain.isTemplate && badged.isTemplate && plain.size == badged.size && plain.tiffRepresentation != badged.tiffRepresentation,
              "Menu-bar dot must change the icon without resizing it or losing native contrast")
    try check(!settings.window!.isVisible, "Update checks must not open a window")
    if let path = ProcessInfo.processInfo.environment["BUFFERA_UPDATE_PREVIEW_DIR"] {
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let target = URL(fileURLWithPath: path).appendingPathComponent("settings-updates-\(L10n.language).png")
        // Offscreen content has no window backing; render it on its native background.
        let preview = NSImage(size: root.bounds.size, flipped: false) { bounds in
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            NSImage(cgImage: bitmap.cgImage!, size: root.bounds.size).draw(in: bounds)
            return true
        }
        try NSBitmapImageRep(data: preview.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: target)
        let icon = NSImage(size: NSSize(width: 200, height: 180), flipped: false) { bounds in
            NSColor.white.setFill(); bounds.fill()
            badged.draw(in: bounds)
            return true
        }
        let image = NSBitmapImageRep(data: icon.tiffRepresentation!)!
        try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("menu-bar-dot.png"))
    }
}
