import AppKit
import BufferaCore
import BufferaLocalization

/// Exercises real controls with isolated preferences, no model manager and a fake clipboard.
func runSetupSmokeTest() throws {
    let activeLanguage = L10n.language
    NSApplication.shared.setActivationPolicy(.prohibited)
    let suite = "Buffera.SetupChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let access = MCPAccess(directory: directory)
    var initial = SetupPreferences(defaults: defaults, mcpEnabled: false, snapshots: [])
    initial.appearance = HistoryAppearance(mode: .right, columns: 3, visibleRows: 9, sidebarVisible: false)
    initial.limits = HistoryLimits(maxCount: 42_000, maxBytes: 3_500_000_000)
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw HistoryError.database(message) }
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func control<T: NSView>(_ root: NSView, _ id: String, _ type: T.Type = T.self) throws -> T {
        guard let found = views(root).first(where: { $0.identifier?.rawValue == id }) as? T else {
            throw HistoryError.database("Missing setup control: \(id)")
        }
        return found
    }
    let controller = SetupWindow(initial: initial, modelsAvailable: true, access: access,
                                 bundleURL: URL(fileURLWithPath: "/Applications/Fixture's Buffera.app"), shortcuts: .defaults)
    let root = controller.window!.contentView!
    func click(_ id: String) throws { try control(root, id, NSButton.self).performClick(nil) }
    func capture(_ name: String) throws {
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: "/tmp/buffera-\(name)-\(activeLanguage).png"))
        }
    }
    var applied: SetupPreferences?
    var attempts = 0
    controller.onFinish = { value, _ in
        attempts += 1
        if attempts == 1 { throw HistoryError.database("Fixture write failed") }
        applied = value
    }
    var copied = ""
    controller.onCopyConfiguration = { copied = $0 }
    try capture("setup-language")
    let language = try control(root, "setup.language", NSPopUpButton.self)
    language.selectItem(at: 2)
    try click("setup.skip")
    try check(controller.draft.language == initial.language, "Skipping must discard page edits")
    let columns = try control(root, "setup.columns", NSPopUpButton.self)
    columns.selectItem(at: 3)
    try click("setup.skip")
    try check(controller.draft.appearance == initial.appearance, "Skipping must preserve existing appearance")
    try capture("setup-keys")
    let keyTexts = views(root).compactMap { $0 as? NSTextField }.map(\.stringValue)
    try check(keyTexts.contains { $0.contains("⌘⌥C") && $0.contains("⌘⌥V") }, "Quick selection must show complete combinations")
    try check(!keyTexts.contains { $0.contains("Esc") || $0.contains("⌘V") }, "No redundant shortcuts in the setup reminder")
    try click("setup.next")
    try capture("setup-storage")
    try click("setup.next")
    try check(controller.draft.limits == initial.limits, "An untouched storage page must preserve fractional and custom limits")
    try click("setup.back")
    try click("setup.skip")
    try check(controller.draft.limits == initial.limits, "Skipping storage preserves custom limits")
    try capture("setup-mcp")
    let permission = try control(root, "mcp.enabled", NSButton.self)
    permission.performClick(nil)
    try check(controller.draft.mcpEnabled && !access.isEnabled(), "MCP permission must stay staged")
    for (id, expected, name) in [
        ("mcp.copyClaudeCommand", MCPAccess.addCommand(for: .claudeCode, executableURL: URL(fileURLWithPath: "/Applications/Fixture's Buffera.app/Contents/MacOS/BufferaMCP")), "Claude Code"),
        ("mcp.copyCodexCommand", MCPAccess.addCommand(for: .codex, executableURL: URL(fileURLWithPath: "/Applications/Fixture's Buffera.app/Contents/MacOS/BufferaMCP")), "Codex"),
        ("mcp.copyConfiguration", try MCPAccess.configuration(executableURL: URL(fileURLWithPath: "/Applications/Fixture's Buffera.app/Contents/MacOS/BufferaMCP")), "JSON")
    ] {
        try click(id)
        try check(copied == expected, "Copy and displayed command must use the canonical MCP formatter")
        try check(try control(root, id + ".value", NSTextField.self).stringValue == expected, "Displayed configuration differs from clipboard")
        try check(try control(root, "mcp.status", NSTextField.self).stringValue.contains(name), "Copy feedback must identify its client")
    }
    controller.onCopyConfiguration = { _ in throw HistoryError.database("Fixture clipboard failure") }
    try click("mcp.copyCodexCommand")
    try check(try control(root, "mcp.status", NSTextField.self).textColor == .systemRed, "Failed copy must not report success")
    try click("setup.next")
    try capture("setup-models")
    try control(root, "setup.embedding", NSButton.self).performClick(nil)
    try check(!access.isEnabled() && defaults.persistentDomain(forName: suite)?.isEmpty != false,
              "Walking through setup must not persist settings or permissions")
    try click("setup.next")
    try check(applied == nil && controller.step == 5, "A failed finish must keep the draft and current page")
    try click("setup.next")
    try check(applied?.mcpEnabled == true && applied?.embeddingEnabled == true && attempts == 2,
              "Retry must apply the retained draft")

    let cancelled = SetupWindow(initial: initial, modelsAvailable: false, access: access)
    var skipped = false
    cancelled.onSkip = { skipped = true }
    cancelled.onFinish = { _, _ in throw HistoryError.database("Cancel applied a draft") }
    cancelled.window?.performClose(nil)
    try check(skipped && !access.isEnabled(), "Closing setup must skip without granting permission")

    let introduction = NearbyIntroductionWindow(defaults: defaults)
    var accepted: Bool?
    introduction.onDismiss = { accepted = $0 }
    let introRoot = introduction.window!.contentView!
    introRoot.wantsLayer = true
    introRoot.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    introRoot.layoutSubtreeIfNeeded()
    for view in views(introRoot) where view is NSControl && !view.isHiddenOrHasHiddenAncestor {
        try check(introRoot.bounds.insetBy(dx: -1, dy: -1).contains(introRoot.convert(view.bounds, from: view)),
                  "Nearby explanation control is clipped")
    }
    if let bitmap = introRoot.bitmapImageRepForCachingDisplay(in: introRoot.bounds) {
        introRoot.cacheDisplay(in: introRoot.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/buffera-nearby-intro-\(activeLanguage).png"))
    }
    try control(introRoot, "nearby.cancel", NSButton.self).performClick(nil)
    try check(accepted == false && !defaults.bool(forKey: NearbyIntroductionWindow.preferenceKey),
              "Cancel must neither navigate nor suppress future explanation")
    let confirmed = NearbyIntroductionWindow(defaults: defaults)
    confirmed.onDismiss = { accepted = $0 }
    try control(confirmed.window!.contentView!, "nearby.accept", NSButton.self).performClick(nil)
    try check(accepted == true && defaults.bool(forKey: NearbyIntroductionWindow.preferenceKey),
              "Confirm must honor the remembered preference")
    // Exercise the actual history action: explanation first, no selection commit,
    // then chronological navigation and restoration through the visible back button.
    defaults.set(false, forKey: NearbyIntroductionWindow.preferenceKey)
    let panel = HistoryPanel(introductionDefaults: defaults)
    panel.window.delegate = nil
    panel.window.permitsOffscreenFrame = true
    panel.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    panel.window.alphaValue = 0; panel.window.orderFront(nil)
    defer { panel.window.orderOut(nil) }
    let panelRoot = panel.window.contentView!
    let searchField = views(panelRoot).compactMap { $0 as? NSSearchField }.first!
    let sample = ClipSummary(id: 1, date: Date(timeIntervalSince1970: 1_700_000_000), kind: .text,
                             title: "Contract fixture", text: "Contract fixture", source: "Test", byteCount: 16)
    searchField.stringValue = "contract"
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    panel.receive([sample], total: 1, offset: 0)
    var copies = 0, nearbyRequests = 0
    panel.onConfirm = { _ in copies += 1 }
    panel.requestNearby = { id, token in
        nearbyRequests += 1
        panel.receiveNearby([sample], anchorID: id, token: token)
    }
    func invokeNearby() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: panel.window.windowNumber, context: nil, characters: "n",
            charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        _ = panel.window.onKeyDown?(event)
    }
    func visibleIntroduction() throws -> NSView {
        guard let root = NSApp.windows.first(where: { window in
            window.isVisible && window.contentView.map { views($0).contains { $0.identifier?.rawValue == "nearby.accept" } } == true
        })?.contentView else { throw HistoryError.database("First nearby action did not explain itself") }
        return root
    }
    invokeNearby()
    let firstIntro = try visibleIntroduction()
    panel.window.onFlagsChanged?([])
    try check(nearbyRequests == 0 && copies == 0 && !panel.isShowingNearby,
              "Opening explanation must neither load nearby nor copy a selection")
    try control(firstIntro, "nearby.cancel", NSButton.self).performClick(nil)
    try check(!panel.isShowingNearby && searchField.stringValue == "contract" && copies == 0,
              "Cancel must preserve the search without copying")
    invokeNearby()
    try control(try visibleIntroduction(), "nearby.accept", NSButton.self).performClick(nil)
    panelRoot.layoutSubtreeIfNeeded()
    try check(nearbyRequests == 1 && panel.isShowingNearby && copies == 0,
              "Confirm must navigate only, without copying")
    try check(try !control(panelRoot, "history.nearbyHeader", NSStackView.self).isHidden,
              "Chronological mode must show its prominent header")
    try control(panelRoot, "history.nearbyBack", NSButton.self).performClick(nil)
    try check(!panel.isShowingNearby && searchField.stringValue == "contract" && panel.selected?.id == 1 && copies == 0,
              "Visible return must restore the original search and selection")
    invokeNearby()
    try check(panel.isShowingNearby && nearbyRequests == 2, "Remembered preference must bypass the next automatic explanation")
    print("PASS: setup draft, skip, cancel, retry, MCP commands and feedback, nearby explanation; \(activeLanguage)")
}
