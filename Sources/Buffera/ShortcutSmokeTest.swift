import AppKit
import Carbon
import BufferaCore
import BufferaLocalization

/// Isolated preferences, real settings controls, and a deterministic Carbon substitute.
func runShortcutSmokeTest() throws {
    let activeLanguage = L10n.language
    NSApplication.shared.setActivationPolicy(.prohibited)
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HistoryError.database(message) }
        checks += 1
    }
    let suite = "Buffera.ShortcutChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    defer { defaults.removePersistentDomain(forName: suite) }
    try check(ShortcutPreferences.load(from: defaults) == .defaults, "Fresh defaults")
    for data in [Data(), Data(#"{"base":"bad","next":"V","previous":"C"}"#.utf8),
                 Data(#"{"base":"commandOption","next":"V","previous":"V"}"#.utf8)] {
        defaults.set(data, forKey: ShortcutPreferences.preferenceKey)
        try check(ShortcutPreferences.load(from: defaults) == .defaults, "Malformed preferences fall back")
    }
    for base in ShortcutPreferences.Base.allCases {
        let value = ShortcutPreferences(base: base, next: "J", previous: "K")
        try value.save(to: defaults)
        try check(ShortcutPreferences.load(from: defaults) == value, "Round trip \(base)")
        try check(value.direction(keyCode: 38, modifiers: base.modifiers.union(.capsLock)) == 1, "Physical J plus Caps Lock")
        try check(value.direction(keyCode: 40, modifiers: base.modifiers) == -1, "Physical K")
        let extra = NSEvent.ModifierFlags([.command, .control, .option, .shift]).subtracting(base.modifiers)
        try check(value.direction(keyCode: 38, modifiers: base.modifiers.union(extra)) == nil, "Extra modifiers do not navigate")
        var gesture = HistoryShortcutGesture(requiredModifiers: base.modifiers)
        gesture.press()
        try check(!gesture.modifiersChanged([]), "Single tap remains open")
        for released: NSEvent.ModifierFlags in [.command, .control, .option, .shift] where base.modifiers.contains(released) {
            gesture.press(); gesture.press()
            try check(!gesture.modifiersChanged(base.modifiers), "Hold does not confirm")
            try check(gesture.modifiersChanged(base.modifiers.subtracting(released)), "Release any required modifier confirms once")
            try check(!gesture.modifiersChanged([]), "No duplicate confirmation")
        }
    }
    for value in [ShortcutPreferences(base: .controlShift, next: "J", previous: "J"),
                  ShortcutPreferences(base: .commandOption, next: "S", previous: "C"),
                  ShortcutPreferences(base: .commandShift, next: "J", previous: "N"),
                  ShortcutPreferences(base: .controlOption, next: "1", previous: "C")] {
        try check((try? value.validate()) == nil, "Invalid/conflicting pair rejected")
    }

    var active: [HotKeys.Binding: UInt32] = [:]
    var blocked: HotKeys.Binding?
    var failRegistration = false
    let hotKeys = HotKeys(preferences: .defaults) { binding, id in
        if failRegistration || binding == blocked { throw HotKeyError(status: -9878) }
        guard active[binding] == nil else { throw HistoryError.database("Registered same key twice") }
        active[binding] = id
        return { active.removeValue(forKey: binding) }
    }
    try hotKeys.register()
    try check(active.count == 1, "Only opener registered while closed")
    try hotKeys.setPreviousEnabled(true)
    let original = active
    let candidate = ShortcutPreferences(base: .controlOption, next: "J", previous: "K")
    blocked = HotKeys.Binding(key: candidate.previousKeyCode, modifiers: candidate.base.carbonModifiers)
    try check((try? hotKeys.apply(candidate)) == nil, "Second registration failure propagates")
    try check(active == original && hotKeys.preferences == .defaults, "Failure rolls back new keys and keeps old registrations")
    blocked = nil
    let swapped = ShortcutPreferences(base: .commandOption, next: "C", previous: "V")
    try hotKeys.apply(swapped)
    try check(active == original, "Swapping letters reuses existing registrations")
    var events: [(Int, Bool)] = []
    hotKeys.onPress = { events.append(($0, $1)) }
    let nextID = active[HotKeys.Binding(key: 8, modifiers: swapped.base.carbonModifiers)]!
    hotKeys.receive(id: nextID, released: false)
    hotKeys.receive(id: nextID, released: false)
    hotKeys.receive(id: nextID, released: true)
    hotKeys.receive(id: nextID, released: false)
    try check(events.map(\.0) == [1, 1, 1] && events.map(\.1) == [false, true, false], "Swap dispatch and repeat tracking")
    try hotKeys.setPreviousEnabled(false)
    try hotKeys.apply(candidate)
    try check(active.count == 1 && hotKeys.preferences == candidate, "Closed history releases probe registration")
    let eventCount = events.count
    hotKeys.receive(id: nextID, released: false)
    try check(events.count == eventCount, "Late event for released binding ignored")

    try ShortcutPreferences.defaults.save(to: defaults)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { try? FileManager.default.removeItem(at: directory) }
    func settingsWindow() -> SettingsWindow {
        SettingsWindow(mcpAccess: MCPAccess(directory: directory), languageDefaults: defaults, limitsDefaults: defaults,
                       themeDefaults: defaults, shortcutDefaults: defaults, frameAutosaveName: nil)
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let controller = settingsWindow()
    controller.onShortcutsChange = { try hotKeys.apply($0) }
    let window = controller.window!
    let root = window.contentView!
    let tabs = descendants(root).compactMap { $0 as? NSSegmentedControl }.first!
    tabs.selectedSegment = 2; _ = tabs.sendAction(tabs.action, to: tabs.target)
    root.layoutSubtreeIfNeeded()
    func control<T: NSView>(_ id: String, as type: T.Type) -> T {
        descendants(root).first { $0.identifier?.rawValue == "shortcuts." + id } as! T
    }
    let base = control("base", as: NSPopUpButton.self)
    let next = control("next", as: NSPopUpButton.self)
    let previous = control("previous", as: NSPopUpButton.self)
    let apply = control("apply", as: NSButton.self)
    let reset = control("reset", as: NSButton.self)
    let status = control("status", as: NSTextField.self)
    try check(base.numberOfItems == 5 && next.numberOfItems == 26 && previous.numberOfItems == 26, "Five bases and alphabet choices")
    base.selectItem(at: 1); next.selectItem(withTitle: "J"); previous.selectItem(withTitle: "K")
    apply.performClick(nil)
    try check(hotKeys.preferences == candidate && ShortcutPreferences.load(from: defaults) == candidate, "Real Apply saves and registers")
    try check(control("hint", as: NSTextField.self).stringValue.contains("⌃⌥J"), "Hint reflects applied shortcut")
    previous.selectItem(withTitle: "J"); apply.performClick(nil)
    try check(status.textColor == .systemRed && ShortcutPreferences.load(from: defaults) == candidate, "Duplicate letters do not persist")
    previous.selectItem(withTitle: "L"); failRegistration = true; apply.performClick(nil)
    try check(status.textColor == .systemRed && hotKeys.preferences == candidate && ShortcutPreferences.load(from: defaults) == candidate,
              "Registration failure does not persist or replace active pair")
    reset.performClick(nil)
    try check(ShortcutPreferences.load(from: defaults) == candidate, "Failed reset preserves preference")
    failRegistration = false; reset.performClick(nil)
    try check(hotKeys.preferences == .defaults && ShortcutPreferences.load(from: defaults) == .defaults, "Reset applies defaults")
    try check(base.indexOfSelectedItem == 0 && next.titleOfSelectedItem == "V" && previous.titleOfSelectedItem == "C", "Reset refreshes controls")
    let reopened = settingsWindow()
    let reopenedTabs = descendants(reopened.window!.contentView!).compactMap { $0 as? NSSegmentedControl }.first!
    reopenedTabs.selectedSegment = 2; _ = reopenedTabs.sendAction(reopenedTabs.action, to: reopenedTabs.target)
    let selected = descendants(reopened.window!.contentView!).first { $0.identifier?.rawValue == "shortcuts.next" } as? NSPopUpButton
    try check(selected?.titleOfSelectedItem == "V", "Reopened settings reflect saved value")
    root.layoutSubtreeIfNeeded()
    for view in [base, next, previous, apply, reset] {
        let frame = root.convert(view.bounds, from: view)
        try check(frame.width > 0 && frame.height > 0 && root.bounds.contains(frame), "Shortcut controls are visible inside settings")
        if let scroll = view.enclosingScrollView {
            let visibleFrame = scroll.contentView.convert(view.bounds, from: view)
            try check(scroll.contentView.bounds.contains(visibleFrame), "Shortcut controls are inside the scroll viewport")
        }
    }
    try check(!window.isVisible, "Smoke test never opens user windows")
    if CommandLine.arguments.contains("--shortcut-preview") {
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layoutSubtreeIfNeeded()
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: "/tmp/buffera-shortcuts-\(activeLanguage).png"))
        }
    }
    if CommandLine.arguments.contains("--shortcut-carbon-check") {
        for base in ShortcutPreferences.Base.allCases {
            let value = ShortcutPreferences(base: base, next: "J", previous: "K")
            let native = HotKeys(preferences: value)
            try native.register()
            try native.setPreviousEnabled(true)
            try native.apply(ShortcutPreferences(base: base, next: "K", previous: "J"))
            var blocker: EventHotKeyRef?
            let result = RegisterEventHotKey(37, base.carbonModifiers,
                EventHotKeyID(signature: 0x42555141, id: 1), GetEventDispatcherTarget(),
                OptionBits(kEventHotKeyExclusive), &blocker)
            guard result == noErr, let blocker else { throw HotKeyError(status: result) }
            defer { UnregisterEventHotKey(blocker) }
            try check((try? native.apply(ShortcutPreferences(base: base, next: "J", previous: "L"))) == nil,
                      "Carbon rejects a reserved second key for \(base)")
            try check(native.isRegistered && native.preferences.next == "K", "Real registration failure retains old pair")
            try native.setPreviousEnabled(false)
        }
    }
    print("PASS: \(checks) shortcut checks (\(activeLanguage)): persistence, five bases, gestures, atomic registration, real settings controls and layout")
}
