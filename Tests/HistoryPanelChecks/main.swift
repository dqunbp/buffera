import AppKit
import BufferaCore

// Run from the repository root. The windows are fully transparent; no
// clipboard, database, or app activation are used. Appearance checks restore
// every preference they touch before asserting their results.
// mkdir -p .build/history-panel-checks
// swiftc -emit-library -emit-module -module-name BufferaCore Sources/BufferaCore/Clip.swift -emit-module-path .build/history-panel-checks/BufferaCore.swiftmodule -o .build/history-panel-checks/libBufferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I .build/history-panel-checks -L .build/history-panel-checks -lBufferaCore -Xlinker -rpath -Xlinker "$PWD/.build/history-panel-checks" -module-cache-path .build/ModuleCache Sources/Buffera/HistoryPanel.swift Sources/Buffera/HistoryShortcutGesture.swift Sources/Buffera/HistoryCardsView.swift Sources/Buffera/ClipCardView.swift Sources/Buffera/HistoryFilters.swift Sources/Buffera/HistoryAppearance.swift Sources/Buffera/BrandIdentity.swift Sources/Buffera/LegacyMigration.swift Sources/Buffera/ClipPreview.swift Sources/Buffera/ClipboardService.swift Tests/HistoryPanelChecks/main.swift -o .build/history-panel-checks/checks
// .build/history-panel-checks/checks

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
    checkCount += 1
    print("PASS", message)
}

func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

func waitUntil(_ description: String, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    if !condition() { fatalError("Timed out: \(description)") }
}

func fixture(_ id: Int) -> ClipSummary {
    ClipSummary(id: Int64(id), date: Date(timeIntervalSince1970: 1_700_000_000), kind: .text,
                title: "Fixture \(id)", text: "Search fixture \(id)", source: "Checks", byteCount: 10)
}

final class PanelHarness {
    struct Request { let query: String; let offset: Int; let limit: Int; let silent: Bool; let filter: SearchFilter }
    let panel = HistoryPanel()
    let search: NSSearchField
    let cards: HistoryCardsView
    var requests: [Request] = []
    var confirmations: [Int64] = []

    init(rows: [ClipSummary] = []) {
        let views = descendants(of: panel.window.contentView!)
        search = views.compactMap { $0 as? NSSearchField }.first!
        cards = views.compactMap { $0 as? HistoryCardsView }.first!
        // Window delegate writes frame preferences on movement; the test moves
        // its offscreen fixture directly and does not exercise frame persistence.
        panel.window.delegate = nil
        panel.window.permitsOffscreenFrame = true
        panel.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.window.alphaValue = 0
        panel.window.orderFront(nil)
        panel.window.contentView?.layoutSubtreeIfNeeded()
        panel.request = { [weak self] filter, offset, limit in
            guard let self else { return }
            self.requests.append(Request(query: filter.query, offset: offset, limit: limit,
                                         silent: self.panel.isRefreshingSearchIndex, filter: filter))
        }
        panel.onConfirm = { [weak self] in self?.confirmations.append($0) }
        search.stringValue = "fixture"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        panel.receive(rows, total: rows.count, offset: 0)
        requests.removeAll()
    }

    func startSilentRefresh() {
        let count = requests.count
        panel.searchIndexDidChange()
        waitUntil("silent refresh") { self.requests.count > count }
        check(requests.last!.silent, "OCR refresh uses the silent request path")
    }

    func enter() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: panel.window.windowNumber, context: nil,
                                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        check(panel.window.onKeyDown?(event) == true, "panel handles Enter through its window keyboard path")
    }

    func finish() { panel.window.orderOut(nil) }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

let entering = PanelHarness()
var completions = 0
let backlog = Timer(timeInterval: 0.1, repeats: true) { timer in
    completions += 1
    entering.panel.searchIndexDidChange()
    if completions == 20 { timer.invalidate() }
}
RunLoop.main.add(backlog, forMode: .common)
entering.panel.searchIndexDidChange()
waitUntil("refresh during sustained OCR backlog") { !entering.requests.isEmpty }
backlog.invalidate()
check(completions < 20, "continuous OCR completions do not postpone refresh until the backlog ends")
entering.enter()
check(!entering.search.isEnabled, "Enter waits while an empty search is loading OCR matches")
entering.panel.receive([fixture(42)], total: 1, offset: 0)
check(entering.confirmations == [42], "pending Enter confirms the first OCR match without deadlocking")
entering.finish()

let failed = PanelHarness()
failed.startSilentRefresh()
failed.enter()
failed.panel.searchFailed(HistoryError.database("Fixture failure"))
check(failed.search.isEnabled && !failed.panel.isRefreshingSearchIndex,
      "failed silent query releases pending Enter and restores search controls")
let beforeRetry = failed.requests.count
failed.search.stringValue = "retry"
failed.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: failed.search))
check(failed.requests.count == beforeRetry + 1 && failed.requests.last!.query == "retry" && !failed.requests.last!.silent,
      "search remains usable after a failed pending Enter")
failed.finish()

let initial = (1...20).map(fixture)
let preserving = PanelHarness(rows: initial)
preserving.panel.move(10)
let originalID = preserving.panel.selected!.id
let originalCard = preserving.cards.card(at: preserving.cards.selectedIndex)
let originalOrigin = preserving.cards.scrollView.contentView.bounds.origin
preserving.startSilentRefresh()
preserving.panel.receive(initial, total: initial.count, offset: 0)
check(originalCard != nil && preserving.cards.card(at: preserving.cards.selectedIndex) === originalCard,
      "identical OCR results retain existing card views")
check(preserving.panel.selected?.id == originalID && preserving.cards.scrollView.contentView.bounds.origin == originalOrigin,
      "identical OCR results keep selection and viewport")

preserving.startSilentRefresh()
let expanded = (1_000..<1_500).map(fixture) + initial
let firstLimit = preserving.requests.last!.limit
preserving.panel.receive(Array(expanded.prefix(firstLimit)), total: expanded.count, offset: 0)
check(preserving.panel.selected?.id == originalID && preserving.panel.isRefreshingSearchIndex
      && preserving.requests.last!.limit > firstLimit,
      "selection beyond the first OCR page triggers a wider query without replacing the list")
preserving.panel.move(-1)
let currentID = preserving.panel.selected!.id
let secondLimit = preserving.requests.last!.limit
preserving.panel.receive(Array(expanded.prefix(secondLimit)), total: expanded.count, offset: 0)
check(preserving.requests.last!.limit > secondLimit && preserving.panel.selected?.id == currentID,
      "additional OCR pages widen progressively while allowing selection changes")
let expandedOrigin = preserving.cards.scrollView.contentView.bounds.origin
preserving.panel.receive(expanded, total: expanded.count, offset: 0)
check(preserving.panel.selected?.id == currentID && !preserving.panel.isRefreshingSearchIndex,
      "expanded OCR results preserve the current selection when it is finally found")
check(preserving.cards.scrollView.contentView.bounds.origin == expandedOrigin,
      "expanded OCR results preserve the visible scroll position")
preserving.finish()

// Exercise settings through the real picker callback and appearance API. Keep
// assertions outside this function so even a regression restores preferences.
func settingsChecks() -> [(Bool, String)] {
    let defaults = UserDefaults.standard
    let keys = ["historyAppearance.mode", "historyAppearance.columns", "historyAppearance.visibleRows",
                "historyAppearance.sidebarVisible", "historyAppearance.sideWidth", "NSWindow Frame BufferaHistory"]
    let saved = keys.map { ($0, defaults.object(forKey: $0)) }
    defer {
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    let harness = PanelHarness(rows: [fixture(50), fixture(51)])
    defer { harness.finish() }
    var results: [(Bool, String)] = []
    var settingsRequests = 0
    harness.panel.onShowSettings = { settingsRequests += 1 }
    let selectedID = harness.panel.selected?.id
    harness.panel.showSettings()
    results.append((settingsRequests == 1 && harness.panel.selected?.id == selectedID
                    && harness.search.stringValue == "fixture",
                    "settings callback preserves the current search and selection"))
    let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                   windowNumber: harness.panel.window.windowNumber, context: nil,
                                   characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
    let handled = harness.panel.window.onKeyDown?(shortcut) == true
    results.append((handled && settingsRequests == 2, "Command-comma uses the same settings callback"))

    harness.panel.window.orderOut(nil)
    let keyWindow = NSApp.keyWindow
    var changed: [HistoryAppearance] = []
    harness.panel.onAppearanceChange = { changed.append($0) }
    let docked = HistoryAppearance(mode: .right, columns: 2, visibleRows: 5, sidebarVisible: false)
    harness.panel.applyAppearance(docked)
    let floating = HistoryAppearance(mode: .floating, columns: 3, visibleRows: 7, sidebarVisible: true)
    harness.panel.applyAppearance(floating)
    results.append((!harness.panel.window.isVisible && NSApp.keyWindow === keyWindow,
                    "changing hidden history layout neither shows it nor takes keyboard focus"))
    results.append((changed.last == floating && HistoryAppearance.load() == floating,
                    "external appearance changes are saved and published to settings"))

    harness.panel.applyAppearance(docked)
    harness.panel.window.orderFront(nil)
    harness.panel.close(restoreFocus: false)
    harness.panel.applyAppearance(floating)
    let deadline = Date(timeIntervalSinceNow: 0.25)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    results.append((!harness.panel.window.isVisible,
                    "changing layout during a docked close finishes hiding the history window"))
    let beforeReopen = settingsRequests
    harness.panel.showSettings()
    results.append((settingsRequests == beforeReopen + 1,
                    "appearance changes during close do not leave the picker stuck in closing state"))
    return results
}
for (passed, message) in settingsChecks() { check(passed, message) }

func shortcutChecks() -> [(Bool, String)] {
    let defaults = UserDefaults.standard
    let keys = ["historyAppearance.mode", "historyAppearance.columns", "historyAppearance.visibleRows",
                "historyAppearance.sidebarVisible", "NSWindow Frame BufferaHistory"]
    let saved = keys.map { ($0, defaults.object(forKey: $0)) }
    var harnesses: [PanelHarness] = []
    defer {
        for harness in harnesses { harness.panel.close(restoreFocus: false); harness.finish() }
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    // Disable dock animations for deterministic synchronous shortcut sequences.
    HistoryAppearance(mode: .floating, columns: 1, visibleRows: 6, sidebarVisible: false).save()
    let clips = (1...20).map(fixture)
    let held = HistoryShortcutGesture.requiredModifiers
    var results: [(Bool, String)] = []

    func opened(load: Bool = true, fromShortcut: Bool = true) -> PanelHarness {
        let harness = PanelHarness(rows: clips)
        harnesses.append(harness)
        harness.panel.open(fromShortcut: fromShortcut)
        if load { harness.panel.receive(clips, total: clips.count, offset: 0) }
        return harness
    }
    func key(_ harness: PanelHarness, code: UInt16, characters: String,
             flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: harness.panel.window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: isRepeat, keyCode: code)!
        harness.panel.window.sendEvent(event)
    }

    let single = opened()
    single.panel.window.onFlagsChanged?(held)
    single.panel.window.onFlagsChanged?([])
    results.append((single.panel.window.isVisible && single.confirmations.isEmpty
                    && single.panel.selected?.id == 1 && single.search.isEnabled,
                    "one opening shortcut remains visible and does not confirm on modifier release"))
    single.panel.shortcutPressed(1)
    single.panel.shortcutPressed(1)
    single.panel.window.onFlagsChanged?([])
    results.append((single.panel.window.isVisible && single.confirmations.isEmpty
                    && single.panel.selected?.id == 3 && single.search.isEnabled,
                    "two later presses in one hold cannot rearm a persistent presentation"))
    single.panel.shortcutPressed(-1)
    single.panel.window.onFlagsChanged?([])
    single.panel.shortcutPressed(-1)
    single.panel.window.onFlagsChanged?([])
    results.append((single.panel.window.isVisible && single.confirmations.isEmpty
                    && single.panel.selected?.id == 1 && single.search.isEnabled,
                    "later separate holds also keep the same presentation persistent"))
    single.panel.close(restoreFocus: false)
    single.panel.open(fromShortcut: true)
    single.panel.receive(clips, total: clips.count, offset: 0)
    single.panel.shortcutPressed(1)
    single.panel.window.onFlagsChanged?([])
    results.append((single.confirmations == [2],
                    "closing a persistent panel allows release confirmation in a fresh opening hold"))

    let cycling = opened()
    cycling.panel.shortcutPressed(1)
    cycling.panel.window.onFlagsChanged?(held)
    results.append((cycling.panel.selected?.id == 2 && cycling.confirmations.isEmpty,
                    "a second press in the opening hold moves once without confirming early"))
    cycling.panel.window.onFlagsChanged?([.option])
    cycling.panel.window.onFlagsChanged?([])
    results.append((cycling.confirmations == [2] && !cycling.search.isEnabled,
                    "releasing Command after cycling confirms the selected record exactly once"))

    let reverse = opened()
    reverse.panel.shortcutPressed(1)
    reverse.panel.shortcutPressed(1)
    reverse.panel.shortcutPressed(-1)
    reverse.panel.window.onFlagsChanged?([.command])
    results.append((reverse.confirmations == [2],
                    "reverse cycling returns to the previous record and releasing Option confirms it"))

    let separate = opened()
    separate.panel.window.onFlagsChanged?([])
    separate.panel.shortcutPressed(1)
    separate.panel.window.onFlagsChanged?([])
    separate.panel.shortcutPressed(-1)
    separate.panel.window.onFlagsChanged?([])
    results.append((separate.confirmations.isEmpty && separate.panel.window.isVisible
                    && separate.panel.selected?.id == 1,
                    "separate shortcut holds move selection while keeping the panel persistent"))

    let repeats = opened()
    repeats.panel.shortcutPressed(1, isRepeat: true)
    key(repeats, code: 9, characters: "v", flags: held, isRepeat: true)
    repeats.panel.window.onFlagsChanged?([])
    results.append((repeats.confirmations.isEmpty && repeats.panel.selected?.id == 1,
                    "global and direct-window autorepeats neither move nor arm an opening tap"))
    key(repeats, code: 9, characters: "v", flags: held)
    key(repeats, code: 9, characters: "v", flags: held, isRepeat: true)
    repeats.panel.window.onFlagsChanged?([])
    results.append((repeats.confirmations.isEmpty && repeats.panel.selected?.id == 2,
                    "a direct-window single tap moves once and ignores its autorepeat"))
    key(repeats, code: 9, characters: "v", flags: held)
    key(repeats, code: 8, characters: "c", flags: held)
    repeats.panel.window.onFlagsChanged?([])
    results.append((repeats.confirmations.isEmpty && repeats.panel.window.isVisible
                    && repeats.panel.selected?.id == 2 && repeats.search.isEnabled,
                    "direct-window V then C keeps an already persistent presentation open"))

    let directOpening = opened()
    key(directOpening, code: 9, characters: "v", flags: held)
    key(directOpening, code: 8, characters: "c", flags: held)
    directOpening.panel.window.onFlagsChanged?([])
    results.append((directOpening.confirmations == [1] && !directOpening.search.isEnabled,
                    "direct-window V then C confirms when the initial opening hold is still active"))

    let ordinary = opened(fromShortcut: false)
    ordinary.panel.shortcutPressed(1)
    key(ordinary, code: 9, characters: "v", flags: held)
    key(ordinary, code: 8, characters: "c", flags: held)
    ordinary.panel.window.onFlagsChanged?([])
    results.append((ordinary.panel.window.isVisible && ordinary.confirmations.isEmpty
                    && ordinary.panel.selected?.id == 2 && ordinary.search.isEnabled,
                    "a normal menu opening remains persistent through global and direct-window cycling"))

    let loading = opened(load: false)
    loading.panel.shortcutPressed(1)
    loading.panel.shortcutPressed(1)
    loading.panel.window.onFlagsChanged?([])
    results.append((loading.confirmations.isEmpty && !loading.search.isEnabled,
                    "cycling release waits while the initial history request is loading"))
    loading.panel.receive(clips, total: clips.count, offset: 0)
    results.append((loading.confirmations == [3],
                    "the loaded history applies pending moves before confirming the chosen record"))

    let escaped = opened(load: false)
    escaped.panel.shortcutPressed(1)
    escaped.panel.window.onFlagsChanged?([])
    key(escaped, code: 53, characters: "\u{1b}")
    escaped.panel.receive(clips, total: clips.count, offset: 0)
    results.append((!escaped.panel.window.isVisible && escaped.confirmations.isEmpty,
                    "Escape cancels deferred shortcut confirmation before history arrives"))
    escaped.panel.open(fromShortcut: true)
    escaped.panel.receive(clips, total: clips.count, offset: 0)
    escaped.panel.window.onFlagsChanged?([])
    results.append((escaped.panel.window.isVisible && escaped.confirmations.isEmpty && escaped.search.isEnabled,
                    "reopening after Escape starts a fresh persistent single-tap gesture"))

    let failedCopy = opened()
    failedCopy.panel.shortcutPressed(1)
    failedCopy.panel.window.onFlagsChanged?([])
    failedCopy.panel.failed(HistoryError.database("Fixture copy failure"))
    failedCopy.panel.window.onFlagsChanged?([])
    failedCopy.panel.shortcutPressed(1)
    failedCopy.panel.window.onFlagsChanged?([])
    results.append((failedCopy.confirmations == [2] && failedCopy.search.isEnabled
                    && failedCopy.panel.selected?.id == 3,
                    "copy failure restores interaction without retrying on release or the next single tap"))

    let failedGesture = opened()
    failedGesture.panel.shortcutPressed(1)
    failedGesture.panel.failed(HistoryError.database("Fixture interaction failure"))
    failedGesture.panel.window.onFlagsChanged?([])
    results.append((failedGesture.confirmations.isEmpty && failedGesture.search.isEnabled,
                    "failure while cycling cancels the armed gesture before modifier release"))

    let failedInitial = opened(load: false)
    failedInitial.panel.searchFailed(HistoryError.database("Fixture initial request failure"))
    failedInitial.search.stringValue = "retry"
    failedInitial.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                         object: failedInitial.search))
    failedInitial.panel.receive(clips, total: clips.count, offset: 0)
    failedInitial.panel.shortcutPressed(1)
    failedInitial.panel.shortcutPressed(1)
    failedInitial.panel.window.onFlagsChanged?([])
    results.append((failedInitial.panel.window.isVisible && failedInitial.confirmations.isEmpty
                    && failedInitial.panel.selected?.id == 3 && failedInitial.search.isEnabled,
                    "an initial query failure cancels release confirmation for the remaining presentation"))

    if NSEvent.modifierFlags.intersection(held).isEmpty {
        let polled = PanelHarness(rows: clips)
        harnesses.append(polled)
        var ended = 0
        polled.panel.onShortcutGestureEnd = { ended += 1 }
        polled.panel.open(fromShortcut: true)
        polled.panel.receive(clips, total: clips.count, offset: 0)
        let deadline = Date(timeIntervalSinceNow: 0.25)
        while ended == 0, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        results.append((ended == 1 && polled.panel.window.isVisible && polled.confirmations.isEmpty,
                        "modifier polling ends a quick first tap when its flagsChanged event was missed"))
        polled.panel.shortcutPressed(1)
        polled.panel.shortcutPressed(1)
        polled.panel.window.onFlagsChanged?([])
        results.append((ended == 1 && polled.panel.window.isVisible && polled.confirmations.isEmpty
                        && polled.panel.selected?.id == 3 && polled.search.isEnabled,
                        "a polling-ended opening hold stays persistent through later cycling"))
    } else {
        print("SKIP modifier polling check while shortcut modifiers are physically held")
    }
    return results
}
for (passed, message) in shortcutChecks() { check(passed, message) }

func selectionLifecycleChecks() -> [(Bool, String)] {
    let defaults = UserDefaults.standard
    let keys = ["historyAppearance.mode", "historyAppearance.columns", "historyAppearance.visibleRows",
                "historyAppearance.sidebarVisible", "NSWindow Frame BufferaHistory"]
    let saved = keys.map { ($0, defaults.object(forKey: $0)) }
    var harnesses: [PanelHarness] = []
    defer {
        for harness in harnesses { harness.panel.close(restoreFocus: false); harness.finish() }
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    HistoryAppearance(mode: .floating, columns: 1, visibleRows: 6, sidebarVisible: true).save()
    let clips = (1...20).map(fixture)
    var results: [(Bool, String)] = []
    func harness(_ rows: [ClipSummary] = (1...20).map(fixture)) -> PanelHarness {
        let value = PanelHarness(rows: rows)
        harnesses.append(value)
        return value
    }
    func escape(_ value: PanelHarness) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: value.panel.window.windowNumber, context: nil,
                                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                    isARepeat: false, keyCode: 53)!
        value.panel.window.sendEvent(event)
    }
    func flushMainQueue() {
        var completed = false
        DispatchQueue.main.async { completed = true }
        waitUntil("queued panel callbacks") { completed }
    }

    let confirmed = harness()
    confirmed.panel.move(5)
    confirmed.enter()
    results.append((confirmed.confirmations == [6], "Enter confirms the selected record rather than the first row"))
    confirmed.panel.clipboardDidCapture(id: 999)
    confirmed.panel.closeAfterConfirmation()
    confirmed.panel.open()
    let reordered = [clips[5], fixture(999)] + clips.filter { $0.id != 6 }
    confirmed.panel.receive(reordered, total: reordered.count, offset: 0)
    results.append((confirmed.panel.selected?.id == 6 && confirmed.cards.selectedIndex == 0,
                    "successful confirmation reopens with the promoted record first and selected"))
    results.append((confirmed.requests.last?.query == "fixture" && confirmed.confirmations == [6],
                    "reopening after confirmation preserves search without confirming again"))

    let deepRows = (1...320).map(fixture)
    let escaped = harness(deepRows)
    escaped.panel.move(190)
    escape(escaped)
    results.append((!escaped.panel.window.isVisible && escaped.confirmations.isEmpty,
                    "Escape closes a deeply selected history without confirming"))
    escaped.panel.open()
    results.append((escaped.requests.last!.limit >= deepRows.count,
                    "reopening requests enough rows to retain a selection beyond the first page"))
    let requestsBeforePartial = escaped.requests.count
    escaped.panel.receive(Array(deepRows.prefix(150)), total: deepRows.count, offset: 0)
    results.append((escaped.requests.count == requestsBeforePartial + 1 && escaped.requests.last!.limit > 150,
                    "a missing retained record widens the query before falling back to the first row"))
    escaped.panel.receive(Array(deepRows.prefix(300)), total: deepRows.count, offset: 0)
    results.append((escaped.panel.selected?.id == 191 && escaped.confirmations.isEmpty,
                    "Escape preserves a selected record when widened history results arrive"))
    escape(escaped)
    escaped.panel.open()
    escape(escaped)
    escaped.panel.receive(deepRows, total: deepRows.count, offset: 0)
    results.append((!escaped.panel.window.isVisible && escaped.confirmations.isEmpty,
                    "a late history result cannot revive an Escape-cancelled presentation"))
    escaped.panel.open()
    escaped.panel.receive(deepRows, total: deepRows.count, offset: 0)
    results.append((escaped.panel.selected?.id == 191,
                    "Escape while reopening history retains the still-pending choice"))

    let captured = harness()
    captured.panel.move(4)
    escape(captured)
    let hiddenRequests = captured.requests.count
    captured.panel.clipboardDidCapture(id: 1000)
    results.append((!captured.panel.window.isVisible && captured.requests.count == hiddenRequests,
                    "an external copy while hidden does not open or query the panel"))
    captured.panel.open()
    let withNew = [fixture(1000)] + clips
    captured.panel.receive(withNew, total: withNew.count, offset: 0)
    results.append((captured.panel.selected?.id == 1000 && captured.cards.selectedIndex == 0,
                    "the next opening selects the new copy instead of the retained old choice"))
    captured.panel.move(6)
    captured.panel.clipboardDidCapture(id: 8)
    let repeated = [clips[7]] + withNew.filter { $0.id != 8 }
    captured.panel.receive(repeated, total: repeated.count, offset: 0)
    results.append((captured.panel.selected?.id == 8 && captured.cards.selectedIndex == 0,
                    "copying an existing record while visible selects its promoted identity"))

    let excluded = harness()
    excluded.panel.move(7)
    excluded.panel.clipboardDidCapture(id: 5000)
    excluded.panel.receive(clips, total: clips.count, offset: 0)
    results.append((excluded.panel.selected?.id == 8 && excluded.requests.last?.query == "fixture",
                    "a new copy excluded by the current query preserves the prior choice and query"))
    escape(excluded)
    excluded.panel.clipboardDidCapture(id: 5001)
    excluded.panel.open()
    excluded.panel.receive(clips, total: clips.count, offset: 0)
    results.append((excluded.panel.selected?.id == 8,
                    "an excluded copy received while hidden also preserves the matching prior choice"))

    let pending = harness()
    pending.panel.open()
    pending.panel.move(1)
    pending.panel.move(1)
    pending.panel.clipboardDidCapture(id: 1000)
    pending.panel.receive(withNew, total: withNew.count, offset: 0)
    results.append((pending.panel.selected?.id == 2 && pending.confirmations.isEmpty,
                    "capture-triggered refresh preserves moves queued while history was loading"))

    let filtered = harness()
    let views = descendants(of: filtered.panel.window.contentView!)
    let filters = views.compactMap { $0 as? HistoryFilters }.first!
    filtered.panel.setSources(["Checks", "Other"])
    let filterRows = descendants(of: filters.sidebar).compactMap { $0 as? NSButton }
    filterRows.first { $0.title == "Текст" }!.performClick(nil)
    filterRows.first { $0.title == "Checks" }!.performClick(nil)
    let scope = views.compactMap { $0 as? NSSegmentedControl }.first!
    scope.selectedSegment = 1
    _ = NSApp.sendAction(scope.action!, to: scope.target, from: scope)
    filtered.panel.receive(clips, total: clips.count, offset: 0)
    filtered.panel.move(2)
    filtered.enter()
    filtered.panel.closeAfterConfirmation()
    filtered.panel.open()
    let retainedFilters = filtered.requests.last!.filter
    results.append((retainedFilters.query == "fixture" && retainedFilters.kind == .text
                    && retainedFilters.source == "Checks" && retainedFilters.favoritesOnly,
                    "confirmation and reopening retain the query, type, app, and favorites filters"))
    filtered.panel.receive(clips, total: clips.count, offset: 0)
    filtered.panel.clipboardDidCapture(id: 1000)
    let afterCaptureFilters = filtered.requests.last!.filter
    results.append((afterCaptureFilters.query == retainedFilters.query && afterCaptureFilters.kind == retainedFilters.kind
                    && afterCaptureFilters.source == retainedFilters.source && afterCaptureFilters.favoritesOnly,
                    "external-copy refresh leaves active search and independent filters intact"))

    let blurred = harness()
    blurred.panel.open(fromShortcut: true)
    blurred.panel.receive(clips, total: clips.count, offset: 0)
    blurred.panel.shortcutPressed(1)
    blurred.panel.window.resignKey()
    blurred.panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: blurred.panel.window))
    blurred.panel.window.onFlagsChanged?([])
    results.append((blurred.confirmations.isEmpty,
                    "outside blur cancels an armed quick gesture before modifier release can confirm"))
    flushMainQueue()
    results.append((!blurred.panel.window.isVisible && blurred.confirmations.isEmpty,
                    "outside blur closes history without copying the highlighted record"))
    blurred.panel.open()
    blurred.panel.receive(clips, total: clips.count, offset: 0)
    results.append((blurred.panel.selected?.id == 2,
                    "reopening after outside blur retains the unconfirmed selection"))

    let reopened = harness()
    reopened.panel.open()
    reopened.panel.receive(clips, total: clips.count, offset: 0)
    flushMainQueue()
    reopened.panel.window.resignKey()
    reopened.panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: reopened.panel.window))
    reopened.panel.close(restoreFocus: false)
    reopened.panel.open()
    reopened.panel.receive(clips, total: clips.count, offset: 0)
    reopened.panel.window.resignKey()
    flushMainQueue()
    results.append((reopened.panel.window.isVisible && reopened.confirmations.isEmpty,
                    "a queued blur from an older presentation cannot close a newly reopened panel"))
    return results
}
for (passed, message) in selectionLifecycleChecks() { check(passed, message) }

print("\(checkCount) history panel checks passed")
