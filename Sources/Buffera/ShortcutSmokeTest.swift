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
    func key(_ code: Int) -> ShortcutKey { ShortcutKey(code: UInt16(code))! }
    let suite = "Buffera.ShortcutChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    defer { defaults.removePersistentDomain(forName: suite) }
    try check(ShortcutPreferences.load(from: defaults) == .defaults, "Fresh defaults")
    for data in [Data(), Data(#"{"base":"bad","next":"V","previous":"C"}"#.utf8),
                 Data(#"{"base":"commandOption","next":"V","previous":"V"}"#.utf8),
                 Data(#"{"base":"control","next":255,"previous":18}"#.utf8)] {
        defaults.set(data, forKey: ShortcutPreferences.preferenceKey)
        try check(ShortcutPreferences.load(from: defaults) == .defaults, "Malformed preferences fall back")
    }
    for base in ShortcutPreferences.Base.allCases {
        let value = ShortcutPreferences(base: base, next: key(kVK_ANSI_J), previous: key(kVK_ANSI_K))
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
    for value in [ShortcutPreferences(base: .controlShift, next: key(kVK_ANSI_J), previous: key(kVK_ANSI_J)),
                  ShortcutPreferences(base: .commandOption, next: key(kVK_ANSI_S), previous: key(kVK_ANSI_C)),
                  ShortcutPreferences(base: .commandShift, next: key(kVK_ANSI_J), previous: key(kVK_ANSI_N)),
                  ShortcutPreferences(base: .commandOption, next: key(kVK_ANSI_Comma), previous: key(kVK_ANSI_C))] {
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
    let candidate = ShortcutPreferences(base: .control, next: key(kVK_ANSI_Grave), previous: key(kVK_ANSI_0))
    blocked = HotKeys.Binding(key: candidate.previous.code, modifiers: candidate.base.carbonModifiers)
    try check((try? hotKeys.apply(candidate)) == nil, "Second registration failure propagates")
    try check(active == original && hotKeys.preferences == .defaults, "Failure rolls back new keys and keeps old registrations")
    blocked = nil
    let swapped = ShortcutPreferences(base: .commandOption, next: key(kVK_ANSI_C), previous: key(kVK_ANSI_V))
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

    let legacy = Data(#"{"base":"controlOption","next":"J","previous":"K"}"#.utf8)
    defaults.set(legacy, forKey: ShortcutPreferences.preferenceKey)
    let legacyPreferences = ShortcutPreferences(base: .controlOption, next: key(kVK_ANSI_J), previous: key(kVK_ANSI_K))
    try check(ShortcutPreferences.load(from: defaults) == legacyPreferences, "Legacy shortcuts retain their bindings")
    defaults.set(Data(#"{"base":"controlOption","next":"J","previous":"K","pause":"P","skipNext":"O"}"#.utf8),
                 forKey: ShortcutPreferences.preferenceKey)
    let legacyRecording = ShortcutPreferences(base: .controlOption, next: key(kVK_ANSI_J), previous: key(kVK_ANSI_K),
                                               pause: key(kVK_ANSI_P), skipNext: key(kVK_ANSI_O))
    try check(ShortcutPreferences.load(from: defaults) == legacyRecording, "Legacy recording bindings are preserved")
    var recording = candidate
    recording.pause = key(kVK_ANSI_P); recording.skipNext = key(kVK_ANSI_O)
    try recording.save(to: defaults)
    try check(ShortcutPreferences.load(from: defaults) == recording, "Recording shortcuts round trip")
    try hotKeys.apply(recording)
    try check(active.count == 3, "Recording shortcuts remain global with history closed")
    var pauses = 0, skips = 0
    hotKeys.onPause = { pauses += 1 }; hotKeys.onSkipNext = { skips += 1 }
    for recorded in [key(kVK_ANSI_P), key(kVK_ANSI_O)] {
        let id = active[HotKeys.Binding(key: recorded.code, modifiers: recording.base.carbonModifiers)]!
        hotKeys.receive(id: id, released: false)
        hotKeys.receive(id: id, released: false)
        hotKeys.receive(id: id, released: true)
    }
    try check(pauses == 1 && skips == 1, "Recording commands ignore held-key repeats")
    for recorded in [key(kVK_ANSI_P), key(kVK_ANSI_O)] {
        try hotKeys.setPreviousEnabled(true)
        let id = active[HotKeys.Binding(key: recorded.code, modifiers: recording.base.carbonModifiers)]!
        hotKeys.receive(id: id, released: false)
        let beforeReset = pauses + skips
        hotKeys.resetNavigationPressedKeys() // Gesture completion.
        hotKeys.receive(id: id, released: false)
        try hotKeys.setPreviousEnabled(false)
        hotKeys.resetNavigationPressedKeys() // History dismissal.
        hotKeys.receive(id: id, released: false)
        try check(pauses + skips == beforeReset, "History resets preserve held recording shortcut \(recorded.title)")
        try hotKeys.apply(recording)
        hotKeys.receive(id: id, released: false)
        try check(pauses + skips == beforeReset, "Reapplying bindings preserves held recording shortcut \(recorded.title)")
        hotKeys.receive(id: id, released: true)
        hotKeys.receive(id: id, released: false)
        try check(pauses + skips == beforeReset + 1, "Recording shortcut \(recorded.title) fires again after release")
        hotKeys.receive(id: id, released: true)
    }
    let navigationID = active[HotKeys.Binding(key: recording.next.code, modifiers: recording.base.carbonModifiers)]!
    var captured: [(UInt16, NSEvent.ModifierFlags)] = []
    hotKeys.onCapture = { code, modifiers in captured.append((code, modifiers)); return true }
    let beforeCapture = events.count
    hotKeys.receive(id: navigationID, released: false)
    hotKeys.onCapture = nil
    hotKeys.resetNavigationPressedKeys()
    hotKeys.receive(id: navigationID, released: false)
    try check(captured.count == 1 && captured.first?.0 == recording.next.code && captured.first?.1 == .control,
              "Registered Carbon keys reach the recorder with physical codes and modifiers")
    try check(events.count == beforeCapture, "Capturing a registered key suppresses its action through release")
    hotKeys.receive(id: navigationID, released: true)
    hotKeys.receive(id: navigationID, released: false)
    hotKeys.receive(id: navigationID, released: false)
    try check(events.last?.1 == true, "Navigation still tracks held repeats")
    hotKeys.resetNavigationPressedKeys()
    hotKeys.receive(id: navigationID, released: false)
    try check(events.last?.1 == false, "History reset still clears navigation tracking")
    hotKeys.receive(id: navigationID, released: true)
    var duplicate = recording; duplicate.pause = duplicate.next
    try check((try? hotKeys.apply(duplicate)) == nil && hotKeys.preferences == recording, "Recording conflicts preserve bindings")
    var replacement = recording; replacement.pause = key(kVK_ANSI_Q); replacement.skipNext = key(kVK_ANSI_W)
    blocked = HotKeys.Binding(key: key(kVK_ANSI_W).code, modifiers: recording.base.carbonModifiers)
    let beforeFailure = active
    try check((try? hotKeys.apply(replacement)) == nil && active == beforeFailure, "Last recording binding failure rolls back all new registrations")
    blocked = nil
    try hotKeys.apply(candidate)
    try check(active.count == 1, "Removing recording shortcuts releases registrations")

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
    let tabs = descendants(root).compactMap { $0 as? SettingsNavigation }.first!
    tabs.selectedSegment = 2; _ = tabs.sendAction(tabs.action, to: tabs.target)
    root.layoutSubtreeIfNeeded()
    func control<T: NSView>(_ id: String, as type: T.Type) -> T {
        descendants(root).first { $0.identifier?.rawValue == "shortcuts." + id } as! T
    }
    let next = control("next", as: NSButton.self)
    let previous = control("previous", as: NSButton.self)
    let pause = control("pause", as: NSButton.self)
    let skip = control("skipNext", as: NSButton.self)
    let nextValue = control("value.next", as: NSTextField.self)
    let previousValue = control("value.previous", as: NSTextField.self)
    let pauseValue = control("value.pause", as: NSTextField.self)
    let skipValue = control("value.skipNext", as: NSTextField.self)
    let instruction = control("instruction", as: NSTextField.self)
    let clearPause = control("clear.pause", as: NSButton.self)
    let clearSkip = control("clear.skipNext", as: NSButton.self)
    let apply = control("apply", as: NSButton.self)
    let reset = control("reset", as: NSButton.self)
    let status = control("status", as: NSTextField.self)
    let hint = control("hint", as: NSTextField.self)
    func sendKey(_ code: Int, modifiers: NSEvent.ModifierFlags = [], characters: String = "", repeat isRepeat: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: UInt16(code))!
        window.sendEvent(event)
    }
    func capture(_ button: NSButton, _ code: Int, modifiers: NSEvent.ModifierFlags = .control) {
        button.performClick(nil)
        sendKey(code, modifiers: modifiers)
    }
    try check(reset.title == L10n.text("Сбросить сочетания"), "Reset action must name the shortcuts it restores")
    let changeTitle = L10n.text("Изменить")
    let assignTitle = L10n.text("Назначить")
    let unassignedTitle = L10n.text("Не назначено")
    try check(next.title == changeTitle && previous.title == changeTitle && pause.title == assignTitle && skip.title == assignTitle,
              "Recorder buttons name the available actions")
    try check(nextValue.stringValue == "⌘⌥V" && previousValue.stringValue == "⌘⌥C"
              && pauseValue.stringValue == unassignedTitle && skipValue.stringValue == unassignedTitle,
              "The adjacent values show the current bindings")
    try check(instruction.stringValue.contains(changeTitle) && instruction.stringValue.contains(assignTitle),
              "The capture instruction names both actions")
    next.performClick(nil)
    try check(next.title == L10n.text("Нажмите сочетание…") && nextValue.stringValue == "⌘⌥V",
              "Recording prompts for keys while keeping the current value visible")
    sendKey(kVK_ANSI_Grave, modifiers: .control, repeat: true)
    try check(next.title == L10n.text("Нажмите сочетание…"), "Held-key repeats do not set the draft")
    sendKey(kVK_ANSI_Grave)
    try check(status.textColor == .systemRed, "A shortcut requires supported modifiers")
    sendKey(kVK_F1, modifiers: .control)
    try check(status.stringValue == L10n.text("Выберите букву, цифру или клавишу с символом."), "Unsupported key shows an error")
    sendKey(kVK_Escape)
    try check(next.title == changeTitle && nextValue.stringValue == "⌘⌥V" && status.isHidden,
              "Escape cancels capture and keeps the earlier value")
    previous.performClick(nil)
    _ = window.makeFirstResponder(nil)
    try check(previous.title == changeTitle && previousValue.stringValue == "⌘⌥C", "Focus loss stops capture")
    try check(hint.stringValue == ShortcutPreferences.defaults.usageHint && !hint.isHidden, "The hint starts with the saved pair")
    let beforeDraftRegistrations = active
    capture(next, kVK_ANSI_C)
    try check(nextValue.stringValue == "⌃C" && previousValue.stringValue == "⌃C",
              "Changing the shared modifiers can create a conflict with an existing key")
    try check(status.stringValue == ShortcutPreferenceError.duplicate("⌃C").localizedDescription
              && status.textColor == .systemRed && !apply.isEnabled && hint.isHidden,
              "The duplicate is identified immediately and disables Apply")
    previous.performClick(nil)
    try check(!status.isHidden && !apply.isEnabled, "The warning stays visible while recording a replacement")
    sendKey(kVK_ANSI_C, modifiers: .control)
    apply.performClick(nil)
    try check(active == beforeDraftRegistrations && ShortcutPreferences.load(from: defaults) == .defaults,
              "Two Ctrl+C assignments never reach registration or saved preferences")
    next.performClick(nil)
    sendKey(kVK_ANSI_Grave, modifiers: .control, characters: "ё")
    try check(nextValue.stringValue == "⌃`" && previousValue.stringValue == "⌃C" && next.title == changeTitle,
              "Physical keys are recorded independently of characters and share the modifiers")
    capture(previous, kVK_ANSI_0)
    try check(apply.isEnabled && !hint.isHidden && hint.stringValue == candidate.usageHint
              && hint.stringValue.contains("⌃`") && hint.stringValue.contains("0"),
              "A valid draft restores Apply and updates the gesture hint before saving")
    try check(ShortcutPreferences.load(from: defaults) == .defaults, "Recording edits only the draft")
    apply.performClick(nil)
    try check(hotKeys.preferences == candidate && ShortcutPreferences.load(from: defaults) == candidate, "Real Apply saves and registers Control with punctuation and digits")
    try check(hint.stringValue == candidate.usageHint, "The updated hint is retained after Apply")
    let encoded = try JSONSerialization.jsonObject(with: defaults.data(forKey: ShortcutPreferences.preferenceKey)!) as? [String: Any]
    try check(encoded?["next"] as? Int == kVK_ANSI_Grave && encoded?["previous"] as? Int == kVK_ANSI_0, "Preferences persist physical key codes")
    capture(previous, kVK_ANSI_Grave)
    try check(!apply.isEnabled && status.stringValue == ShortcutPreferenceError.duplicate("⌃`").localizedDescription
              && ShortcutPreferences.load(from: defaults) == candidate, "Duplicates keep the previously saved pair")
    capture(previous, kVK_ANSI_L)
    failRegistration = true; apply.performClick(nil)
    try check(status.textColor == .systemRed && hotKeys.preferences == candidate && ShortcutPreferences.load(from: defaults) == candidate,
              "Registration failure does not persist or replace active pair")
    reset.performClick(nil)
    try check(ShortcutPreferences.load(from: defaults) == candidate, "Failed reset preserves preference")
    failRegistration = false; reset.performClick(nil)
    try check(hotKeys.preferences == .defaults && ShortcutPreferences.load(from: defaults) == .defaults, "Reset applies defaults")
    try check(nextValue.stringValue == "⌘⌥V" && previousValue.stringValue == "⌘⌥C", "Reset refreshes the shortcut values")
    capture(next, kVK_ANSI_S, modifiers: [.command, .option])
    try check(!apply.isEnabled && status.stringValue == ShortcutPreferenceError.reserved("⌘⌥S").localizedDescription,
              "Shortcuts reserved by Buffera are flagged before Apply")
    reset.performClick(nil)
    try check(apply.isEnabled && !hint.isHidden && hint.stringValue == ShortcutPreferences.defaults.usageHint,
              "Reset clears invalid draft state and restores the default hint")
    capture(pause, kVK_ANSI_P, modifiers: [.command, .option])
    capture(skip, kVK_ANSI_O, modifiers: [.command, .option])
    apply.performClick(nil)
    try check(ShortcutPreferences.load(from: defaults).pause == key(kVK_ANSI_P) && hotKeys.preferences.skipNext == key(kVK_ANSI_O), "Settings save both recording actions")
    clearPause.performClick(nil)
    apply.performClick(nil)
    try check(hotKeys.preferences.pause == nil && hotKeys.preferences.skipNext == key(kVK_ANSI_O), "Clearing an optional shortcut leaves the other assigned")
    reset.performClick(nil)
    try check(!clearPause.isEnabled && !clearSkip.isEnabled && pause.title == assignTitle && skip.title == assignTitle,
              "Reset removes optional recording shortcuts and restores the assign actions")
    let reopened = settingsWindow()
    let reopenedTabs = descendants(reopened.window!.contentView!).compactMap { $0 as? SettingsNavigation }.first!
    reopenedTabs.selectedSegment = 2; _ = reopenedTabs.sendAction(reopenedTabs.action, to: reopenedTabs.target)
    let selected = descendants(reopened.window!.contentView!).first { $0.identifier?.rawValue == "shortcuts.value.next" } as? NSTextField
    try check(selected?.stringValue == "⌘⌥V", "Reopened settings reflect saved value")
    root.layoutSubtreeIfNeeded()
    for (button, value) in [(next, nextValue), (previous, previousValue), (pause, pauseValue), (skip, skipValue)] {
        let bezel = button.alignmentRect(forFrame: button.frame)
        let ring = bezel.insetBy(dx: -4, dy: -4)
        let parent = button.superview!
        try check(parent.bounds.contains(ring), "Focus ring \(ring) fits its container \(parent.bounds)")
        let buttonCenter = root.convert(bezel, from: parent).midY
        let valueCenter = root.convert(value.bounds, from: value).midY
        try check(abs(buttonCenter - valueCenter) <= 2, "The shortcut value and action are vertically aligned")
    }
    for view in [instruction, next, previous, pause, skip, nextValue, previousValue, pauseValue, skipValue,
                 clearPause, clearSkip, apply, reset] as [NSView] {
        let frame = root.convert(view.bounds, from: view)
        try check(frame.width > 0 && frame.height > 0 && root.bounds.contains(frame), "Shortcut controls are visible inside settings")
        if let scroll = view.enclosingScrollView {
            let visibleFrame = scroll.contentView.convert(view.alignmentRect(forFrame: view.frame), from: view.superview)
            try check(scroll.contentView.bounds.contains(visibleFrame), "Shortcut control \(view.identifier?.rawValue ?? "") \(visibleFrame) exceeds scroll viewport \(scroll.contentView.bounds)")
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
        do {
            let native = HotKeys(preferences: candidate)
            try native.register()
            try native.setPreviousEnabled(true)
            try check(native.isRegistered, "Carbon registers Control with a grave accent and a digit")
        }
        for base in ShortcutPreferences.Base.allCases {
            let value = ShortcutPreferences(base: base, next: key(kVK_ANSI_J), previous: key(kVK_ANSI_K))
            let native = HotKeys(preferences: value)
            try native.register()
            try native.setPreviousEnabled(true)
            try native.apply(ShortcutPreferences(base: base, next: key(kVK_ANSI_K), previous: key(kVK_ANSI_J)))
            var blocker: EventHotKeyRef?
            let result = RegisterEventHotKey(37, base.carbonModifiers,
                EventHotKeyID(signature: 0x42555141, id: 1), GetEventDispatcherTarget(),
                OptionBits(kEventHotKeyExclusive), &blocker)
            guard result == noErr, let blocker else { throw HotKeyError(status: result) }
            defer { UnregisterEventHotKey(blocker) }
            try check((try? native.apply(ShortcutPreferences(base: base, next: key(kVK_ANSI_J), previous: key(kVK_ANSI_L)))) == nil,
                      "Carbon rejects a reserved second key for \(base)")
            try check(native.isRegistered && native.preferences.next == key(kVK_ANSI_K), "Real registration failure retains old pair")
            try native.setPreviousEnabled(false)
        }
    }
    print("PASS: \(checks) shortcut checks (\(activeLanguage)): persistence, capture, gestures, atomic registration, real settings controls and layout")
}
