import AppKit
import BufferaCore

// Run from the repository root. The windows are fully transparent; no
// clipboard, database, or app activation are used. Appearance checks restore
// every preference they touch before asserting their results.
// mkdir -p .build/history-panel-checks
// swiftc -emit-library -emit-module -module-name BufferaCore Sources/BufferaCore/Clip.swift Sources/BufferaCore/ClipboardText.swift Sources/BufferaCore/TextTransformation.swift -emit-module-path .build/history-panel-checks/BufferaCore.swiftmodule -o .build/history-panel-checks/libBufferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I .build/history-panel-checks -L .build/history-panel-checks -lBufferaCore -Xlinker -rpath -Xlinker "$PWD/.build/history-panel-checks" -module-cache-path .build/ModuleCache Sources/Buffera/HistoryPanel.swift Sources/Buffera/CopyTransformOperation.swift Sources/Buffera/CopyTransformMenu.swift Sources/Buffera/NearbyHistoryState.swift Sources/Buffera/HistoryShortcutGesture.swift Sources/Buffera/HistoryCardsView.swift Sources/Buffera/ClipCardView.swift Sources/Buffera/HistoryFilters.swift Sources/Buffera/HistoryAppearance.swift Sources/Buffera/BrandIdentity.swift Sources/Buffera/LegacyMigration.swift Sources/Buffera/ClipPreview.swift Sources/Buffera/ClipboardService.swift Tests/HistoryPanelChecks/main.swift -o .build/history-panel-checks/checks
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
                title: "Fixture \(id)", text: "Search fixture \(id)", source: "Panel Fixture App", byteCount: 10)
}

final class PanelHarness {
    struct Request { let query: String; let offset: Int; let limit: Int; let silent: Bool; let filter: SearchFilter }
    struct NearbyRequest { let anchorID: Int64; let token: Int }
    let panel = HistoryPanel()
    let search: NSSearchField
    let cards: HistoryCardsView
    var requests: [Request] = []
    var nearbyRequests: [NearbyRequest] = []
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
        panel.requestNearby = { [weak self] id, token in
            self?.nearbyRequests.append(NearbyRequest(anchorID: id, token: token))
        }
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
NSApp.finishLaunching()

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
    filtered.panel.setSources(["Panel Fixture App", "Other"])
    let filterRows = descendants(of: filters.sidebar).compactMap { $0 as? NSButton }
    filterRows.first { $0.title == "Текст" }!.performClick(nil)
    filterRows.first { $0.title == "Panel Fixture App" }!.performClick(nil)
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
                    && retainedFilters.source == "Panel Fixture App" && retainedFilters.favoritesOnly,
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

func nearbyChecks() -> [(Bool, String)] {
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
    var results: [(Bool, String)] = []
    let originalRows = (1...30).map(fixture)
    func harness() -> PanelHarness {
        let value = PanelHarness(rows: originalRows)
        harnesses.append(value)
        return value
    }
    func key(_ value: PanelHarness, code: UInt16, characters: String,
             flags: NSEvent.ModifierFlags = []) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: value.panel.window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        return value.panel.window.onKeyDown?(event) == true
    }
    func backButton(_ value: PanelHarness) -> NSButton? {
        descendants(of: value.panel.window.contentView!).compactMap { $0 as? NSButton }
            .first { $0.title == "Назад в историю" || $0.accessibilityLabel() == "Назад в историю" }
    }
    func complete(_ value: PanelHarness, rows: [ClipSummary]) {
        guard let request = value.nearbyRequests.last else {
            fatalError("No nearby request for fixture rows \(rows.map(\.id)); selected=\(String(describing: value.panel.selected?.id))")
        }
        value.panel.receiveNearby(rows, anchorID: request.anchorID, token: request.token)
    }

    let centered = harness()
    centered.panel.move(16)
    let centeredOriginalID = centered.panel.selected!.id
    let centeredOriginalOrigin = centered.cards.scrollView.contentView.bounds.origin
    centered.panel.showNearby(id: centeredOriginalID)
    let centeredNeighbors = (0..<21).map { index in
        fixture(index == 10 ? Int(centeredOriginalID) : 3_000 + index)
    }
    complete(centered, rows: centeredNeighbors)
    let centeredCollection = centered.cards.scrollView.documentView as! NSCollectionView
    let anchorFrame = centeredCollection.layoutAttributesForItem(at: IndexPath(item: 10, section: 0))!.frame
    results.append((centered.panel.selected?.id == centeredOriginalID
                    && abs(anchorFrame.midY - centered.cards.scrollView.contentView.bounds.midY) < 1
                    && centered.cards.visibleIndices().contains(9) && centered.cards.visibleIndices().contains(11),
                    "nearby opens with the anchor centered between visible earlier and later captures"))
    centered.panel.returnFromNearby()
    results.append((!centered.panel.isShowingNearby && centered.panel.selected?.id == centeredOriginalID
                    && centered.cards.scrollView.contentView.bounds.origin == centeredOriginalOrigin,
                    "returning from centered nearby restores the original search viewport and selection"))

    let filtered = harness()
    let views = descendants(of: filtered.panel.window.contentView!)
    let filters = views.compactMap { $0 as? HistoryFilters }.first!
    filtered.panel.setSources(["Panel Fixture App", "Other"])
    let filterButtons = descendants(of: filters.sidebar).compactMap { $0 as? NSButton }
    filterButtons.first { $0.title == "Текст" }!.performClick(nil)
    filterButtons.first { $0.title == "Panel Fixture App" }!.performClick(nil)
    let scope = views.compactMap { $0 as? NSSegmentedControl }.first!
    scope.selectedSegment = 1
    _ = NSApp.sendAction(scope.action!, to: scope.target, from: scope)
    filtered.panel.receive(originalRows, total: originalRows.count, offset: 0)
    filtered.panel.move(16)
    let originalID = filtered.panel.selected!.id
    let originalOrigin = filtered.cards.scrollView.contentView.bounds.origin
    var navigations = 0
    filtered.panel.onNavigate = { navigations += 1 }
    let card = filtered.cards.card(at: filtered.cards.selectedIndex)!
    let menuEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: filtered.panel.window.windowNumber, context: nil,
                                     eventNumber: 1, clickCount: 1, pressure: 1)!
    let item = card.menu(for: menuEvent)!.items.first { $0.title == "Показать рядом" }!
    _ = NSApp.sendAction(item.action!, to: item.target, from: item)
    waitUntil("nearby context menu action") { !filtered.nearbyRequests.isEmpty }
    results.append((filtered.panel.isShowingNearby && filtered.nearbyRequests.last?.anchorID == originalID
                    && navigations == 1 && !filtered.search.isEnabled && !scope.isEnabled
                    && filterButtons.allSatisfy { !$0.isEnabled },
                    "card menu opens nearby for the selected filtered result and disables search controls"))
    let neighbors = ClipKind.allCases.enumerated().map { index, kind in
        ClipSummary(id: kind == .text ? originalID : Int64(100 + index),
                    date: Date(timeIntervalSince1970: 1_700_000_100 - Double(index)), kind: kind,
                    title: "Nearby \(kind.rawValue)", text: "Unrelated neighboring material",
                    source: "Other", byteCount: 10)
    }
    complete(filtered, rows: neighbors)
    results.append((filtered.panel.selected?.id == originalID && backButton(filtered)?.isHidden == false,
                    "nearby results select the anchor and expose a visible return button"))
    filtered.panel.move(1)
    let anchorCard = filtered.cards.card(at: 0)!
    let anchorMarker = descendants(of: anchorCard).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityLabel() == "Опорная запись" }
    results.append((filtered.panel.selected?.id != originalID && anchorMarker?.isHidden == false,
                    "the anchor keeps its visible accessible marker after selection moves to a neighbor"))
    var shownKinds: [ClipKind] = []
    filtered.panel.move(-100)
    for _ in neighbors {
        if let kind = filtered.panel.selected?.kind { shownKinds.append(kind) }
        filtered.panel.move(1)
    }
    results.append((shownKinds == ClipKind.allCases && filtered.panel.selected?.source == "Other",
                    "nearby includes every content type and other apps outside search and favorites filters"))
    let beforeScroll = filtered.requests.count
    filtered.panel.move(100)
    results.append((filtered.requests.count == beforeScroll,
                    "navigating to the end of nearby does not request ordinary history pagination"))
    backButton(filtered)!.performClick(nil)
    results.append((!filtered.panel.isShowingNearby && filtered.panel.selected?.id == originalID
                    && filtered.cards.scrollView.contentView.bounds.origin == originalOrigin
                    && filtered.search.isEnabled && scope.isEnabled && scope.selectedSegment == 1
                    && filtered.search.stringValue == "fixture" && navigations == 2,
                    "back restores the exact selection, viewport, query, and favorites scope"))
    let markersAfterBack = descendants(of: filtered.panel.window.contentView!).compactMap { $0 as? NSTextField }
        .filter { $0.accessibilityLabel() == "Опорная запись" && !$0.isHidden }
    results.append((markersAfterBack.isEmpty, "returning to search removes the nearby anchor marker"))
    filtered.panel.refresh(preservingSelection: true)
    let restoredFilter = filtered.requests.last!.filter
    results.append((restoredFilter.query == "fixture" && restoredFilter.kind == .text
                    && restoredFilter.source == "Panel Fixture App" && restoredFilter.favoritesOnly,
                    "back preserves type and source filters for the next ordinary query"))

    let stale = harness()
    stale.panel.move(3)
    let shortcutHandled = key(stale, code: 45, characters: "n", flags: [.command, .shift])
    let firstRequest = stale.nearbyRequests.last!
    stale.panel.returnFromNearby()
    stale.panel.receiveNearby([fixture(900)], anchorID: firstRequest.anchorID, token: firstRequest.token)
    stale.panel.nearbyFailed(HistoryError.missing, token: firstRequest.token)
    results.append((shortcutHandled && !stale.panel.isShowingNearby && stale.panel.selected?.id == 4
                    && stale.search.isEnabled,
                    "Command-Shift-N opens nearby and late success or failure after back is ignored"))
    stale.panel.showNearby(id: 4)
    let secondRequest = stale.nearbyRequests.last!
    complete(stale, rows: [fixture(4), fixture(901)])
    stale.panel.showNearby(id: 901)
    let thirdRequest = stale.nearbyRequests.last!
    stale.panel.receiveNearby([fixture(4)], anchorID: secondRequest.anchorID, token: secondRequest.token)
    stale.panel.nearbyFailed(HistoryError.missing, token: secondRequest.token)
    complete(stale, rows: [fixture(902), fixture(901)])
    results.append((thirdRequest.token != secondRequest.token && stale.panel.selected?.id == 901,
                    "a new nearby anchor supersedes outstanding results and errors from the previous anchor"))
    stale.panel.returnFromNearby()
    results.append((stale.panel.selected?.id == 4 && !stale.panel.isShowingNearby,
                    "changing the nearby anchor retains the original search snapshot for back"))

    let interrupted = harness()
    interrupted.panel.showNearby(id: 2)
    complete(interrupted, rows: [fixture(1001), fixture(2), fixture(1002)])
    let beforeCapture = interrupted.requests.count
    interrupted.panel.clipboardDidCapture(id: 1003)
    interrupted.panel.searchIndexDidChange()
    interrupted.panel.receive([fixture(1003)], total: 1, offset: 0)
    interrupted.panel.searchFailed(HistoryError.database("Stale search failure"))
    let deadline = Date(timeIntervalSinceNow: 0.7)
    while Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
    results.append((interrupted.panel.isShowingNearby && interrupted.panel.selected?.id == 2
                    && interrupted.requests.count == beforeCapture && !interrupted.search.isEnabled,
                    "capture, OCR completion, and stale search responses cannot replace nearby or steal selection"))
    let escapeHandled = key(interrupted, code: 53, characters: "\u{1b}")
    results.append((escapeHandled && !interrupted.panel.isShowingNearby && interrupted.panel.window.isVisible,
                    "Escape leaves nearby without closing the history window"))

    let previewing = harness()
    previewing.panel.showNearby(id: 3)
    complete(previewing, rows: [fixture(3000), fixture(3), fixture(3001)])
    var previewRequests = 0
    previewing.panel.onPreview = { clip, token in
        previewRequests += 1
        previewing.panel.showPreview(.text("Nearby preview fixture"), id: clip.id, token: token)
        // Popovers own a separate window; keep that fixture transparent too.
        for window in NSApp.windows { window.alphaValue = 0 }
    }
    _ = key(previewing, code: 16, characters: "y", flags: .command)
    _ = key(previewing, code: 53, characters: "\u{1b}")
    results.append((previewRequests == 1 && previewing.panel.isShowingNearby
                    && previewing.panel.selected?.id == 3 && previewing.panel.window.isVisible,
                    "the first Escape closes a nearby preview while retaining nearby selection"))
    _ = key(previewing, code: 53, characters: "\u{1b}")
    results.append((!previewing.panel.isShowingNearby && previewing.panel.window.isVisible,
                    "the second Escape returns from nearby after the preview has closed"))

    let missing = harness()
    missing.panel.move(4)
    missing.panel.showNearby(id: 5)
    let missingRequest = missing.nearbyRequests.last!
    missing.panel.nearbyFailed(HistoryError.missing, token: missingRequest.token)
    let missingText = descendants(of: missing.panel.window.contentView!).compactMap { $0 as? NSTextField }
        .map(\.stringValue)
    results.append((missing.panel.isShowingNearby && backButton(missing)?.isHidden == false
                    && missingText.contains(HistoryError.missing.localizedDescription),
                    "a deleted anchor reports its missing state while keeping back available"))
    backButton(missing)!.performClick(nil)
    results.append((!missing.panel.isShowingNearby && missing.panel.selected?.id == 5 && missing.search.isEnabled,
                    "back from a missing anchor restores the prior search"))

    let concealed = harness()
    let secret = ClipSummary(id: 1, date: Date(), kind: .text, title: "Secret fixture title",
                             text: "Secret fixture body", source: "Panel Fixture App", byteCount: 19, isConcealed: true)
    concealed.panel.showNearby(id: 1)
    complete(concealed, rows: [secret])
    let concealedCard = concealed.cards.card(at: concealed.cards.selectedIndex)!
    let cardText = descendants(of: concealedCard).compactMap { $0 as? NSTextField }.map(\.stringValue)
    results.append((cardText.contains("••••••••")
                    && !cardText.contains(where: { $0.contains("Secret fixture") }),
                    "concealed neighboring records remain masked without explicit reveal"))

    let favorite = harness()
    let favoriteScope = descendants(of: favorite.panel.window.contentView!)
        .compactMap { $0 as? NSSegmentedControl }.first!
    favoriteScope.selectedSegment = 1
    _ = NSApp.sendAction(favoriteScope.action!, to: favoriteScope.target, from: favoriteScope)
    let favorites = (1...2).map { id in
        ClipSummary(id: Int64(id), date: Date(), kind: .text, title: "Favorite \(id)",
                    text: "Favorite fixture \(id)", source: "Panel Fixture App", byteCount: 10, isFavorite: true)
    }
    favorite.panel.receive(favorites, total: favorites.count, offset: 0)
    favorite.panel.showNearby(id: 1)
    complete(favorite, rows: favorites)
    var favoriteRequests: [(Int64, Bool)] = []
    favorite.panel.onFavorite = { id, value in favoriteRequests.append((id, value)) }
    _ = key(favorite, code: 2, characters: "d", flags: .command)
    let beforeFavoriteBack = favorite.requests.count
    favorite.panel.returnFromNearby()
    let favoriteBackFilter = favorite.requests.last?.filter
    results.append((favoriteRequests.count == 1 && favoriteRequests.first?.0 == 1
                    && favoriteRequests.first?.1 == false && !favorite.panel.isShowingNearby
                    && favorite.requests.count > beforeFavoriteBack
                    && favoriteBackFilter?.favoritesOnly == true && favoriteBackFilter?.query == "fixture",
                    "back before a nearby favorite callback refreshes the original favorites query"))
    favorite.panel.favoriteFinished(id: 1, isFavorite: false, error: nil)
    favorite.panel.receive([favorites[1]], total: 1, offset: 0)
    results.append((favorite.panel.selected?.id == 2 && favoriteScope.selectedSegment == 1
                    && favorite.search.isEnabled && !favorite.panel.isShowingNearby,
                    "the pending favorite callback and fresh query remove the unfavorited record after back"))

    let newlyConcealed = harness()
    let visibleSecret = ClipSummary(id: 1, date: Date(), kind: .text, title: "Visible secret fixture",
                                    text: "Newly concealed secret body", source: "Panel Fixture App", byteCount: 27)
    let hiddenSecret = ClipSummary(id: visibleSecret.id, date: visibleSecret.date, kind: .text,
                                   title: visibleSecret.title, text: visibleSecret.text, source: "Panel Fixture App",
                                   byteCount: visibleSecret.byteCount, isConcealed: true)
    newlyConcealed.panel.receive([visibleSecret], total: 1, offset: 0)
    newlyConcealed.panel.showNearby(id: 1)
    complete(newlyConcealed, rows: [visibleSecret])
    var concealRequests: [Int64] = []
    newlyConcealed.panel.onConceal = { concealRequests.append($0) }
    _ = key(newlyConcealed, code: 4, characters: "h", flags: [.command, .shift])
    newlyConcealed.panel.refresh(preservingSelection: true)
    complete(newlyConcealed, rows: [hiddenSecret])
    newlyConcealed.panel.close(restoreFocus: false)
    let textAfterClose = descendants(of: newlyConcealed.panel.window.contentView!)
        .compactMap { $0 as? NSTextField }.map(\.stringValue)
    results.append((concealRequests == [1] && !newlyConcealed.panel.window.isVisible
                    && !textAfterClose.contains(where: { $0.contains("Newly concealed secret body") }),
                    "closing after concealment in nearby never renders the original unmasked search snapshot"))
    newlyConcealed.panel.open()
    newlyConcealed.panel.receive([hiddenSecret], total: 1, offset: 0)
    let textAfterReopen = descendants(of: newlyConcealed.panel.window.contentView!)
        .compactMap { $0 as? NSTextField }.map(\.stringValue)
    results.append((newlyConcealed.panel.selected?.id == 1 && textAfterReopen.contains("••••••••")
                    && !textAfterReopen.contains(where: { $0.contains("Newly concealed secret body") }),
                    "reopening loads the concealed record fresh and keeps its contents masked"))

    let closed = harness()
    closed.panel.move(8)
    closed.panel.showNearby(id: 9)
    complete(closed, rows: [fixture(2000), fixture(9), fixture(2001)])
    closed.panel.move(1)
    let closingRequest = closed.nearbyRequests.last!
    closed.panel.close(restoreFocus: false)
    closed.panel.receiveNearby([fixture(2001)], anchorID: closingRequest.anchorID, token: closingRequest.token)
    results.append((!closed.panel.window.isVisible && !closed.panel.isShowingNearby,
                    "closing nearby discards its mode and invalidates outstanding requests"))
    closed.panel.open()
    closed.panel.receive(originalRows, total: originalRows.count, offset: 0)
    results.append((closed.panel.selected?.id == 9 && !closed.panel.isShowingNearby
                    && closed.search.isEnabled && closed.search.stringValue == "fixture",
                    "reopening after nearby restores the original search selection instead of a neighboring record"))
    return results
}
for (passed, message) in nearbyChecks() { check(passed, message) }

func copyTransformChecks() {
    let rows = (1...3).map(fixture)
    let value = PanelHarness(rows: rows)
    defer { value.panel.close(restoreFocus: false); value.finish() }
    var requests: [(Int64, CopyTransformOperation)] = []
    var pendingResult: ((Result<String, Error>) -> Void)?
    var copied: [(Int64, String)] = []
    var pendingCopy: ((Error?) -> Void)?
    var cancellations = 0
    var navigations = 0
    var availability: [(Int64, (Result<[CopyTransformOperation], Error>) -> Void)] = []
    let offered: [CopyTransformOperation] = [.text(.plainText), .text(.unwrapLines)]
    value.panel.requestCopyTransformOperations = { id, completion in
        availability.append((id, completion))
    }
    value.panel.requestCopyTransform = { id, operation, completion in
        requests.append((id, operation)); pendingResult = completion
    }
    value.panel.onCopyTransformed = { id, text, completion in
        copied.append((id, text)); pendingCopy = completion
    }
    value.panel.onCancelCopyTransformed = { cancellations += 1 }
    value.panel.onNavigate = { navigations += 1 }

    func menu(_ harness: PanelHarness, at index: Int = 0) -> NSMenu {
        let card = harness.cards.card(at: index)!
        // rightMouseDown selects the clicked card before presenting its menu.
        // Reproduce that selection while avoiding AppKit's blocking menu popup.
        card.onSelect?()
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: harness.panel.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return card.menu(for: event)!.items.first { $0.tag == ClipCardAction.copyDifferently.rawValue }!.submenu!
    }
    func choose(_ menu: NSMenu, _ operation: CopyTransformOperation) {
        guard let item = menu.items.first(where: { ($0.representedObject as? CopyTransformOperation) == operation }) else {
            fatalError("Missing transformation \(operation.title) in menu: \(menu.items.map(\.title))")
        }
        check(item.isEnabled && item.action != nil && NSApp.sendAction(item.action!, to: item.target, from: item),
              "the context submenu dispatches its chosen transformation through an enabled native menu item")
    }
    func escape(_ harness: PanelHarness) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: harness.panel.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        check(harness.panel.window.onKeyDown?(event) == true, "Escape is handled during a transformed copy")
    }
    func start(_ operation: CopyTransformOperation = .text(.unwrapLines)) {
        let count = requests.count
        choose(menu(value), operation)
        waitUntil("direct transformation request") { requests.count == count + 1 }
    }

    value.startSilentRefresh()
    value.requests.removeAll()
    let initialMenu = menu(value)
    waitUntil("available transformations") { !availability.isEmpty }
    check(availability.first!.0 == 1 && requests.isEmpty && copied.isEmpty
          && initialMenu.items.allSatisfy { !$0.isEnabled },
          "opening the submenu inspects the full source and waits without transforming or copying")
    availability.first!.1(.success(offered))
    waitUntil("filtered transformation menu") { initialMenu.items.contains { $0.representedObject is CopyTransformOperation } }
    check(initialMenu.items.compactMap { $0.representedObject as? CopyTransformOperation } == offered,
          "the context submenu offers only operations applicable to its source")
    // Availability is already cached for this source. Future uncached cards use
    // the same fixture response; operation execution remains asynchronous.
    value.panel.requestCopyTransformOperations = { _, completion in completion(.success(offered)) }
    choose(initialMenu, .text(.unwrapLines))
    waitUntil("context menu starts transformation") { requests.count == 1 }
    check(requests[0].0 == 1 && requests[0].1 == .text(.unwrapLines) && navigations == 1
          && value.panel.isConfirmingCopyTransform && value.panel.window.attachedSheet == nil,
          "one context-menu choice starts the chosen operation without a preview sheet")
    value.panel.receive([fixture(99)], total: 1, offset: 0)
    value.panel.searchFailed(HistoryError.database("Obsolete search failure"))
    check(value.panel.selected?.id == 1,
          "an in-flight search cannot replace the transformation source or display a stale error")
    value.panel.clipboardDidCapture(id: 99)
    value.panel.searchIndexDidChange()
    value.panel.move(1)
    check(value.requests.isEmpty && value.panel.selected?.id == 1 && copied.isEmpty,
          "capture, OCR, and navigation preserve the selected source while its transformation runs")
    pendingResult?(.success("Exact transformed\nvalue"))
    waitUntil("automatic transformed clipboard write") { copied.count == 1 }
    check(copied[0].0 == 1 && copied[0].1 == "Exact transformed\nvalue"
          && value.panel.isConfirmingCopyTransform && value.panel.window.attachedSheet == nil,
          "the exact transformed text goes straight to the copy boundary without another confirmation")

    pendingCopy?(HistoryError.database("Clipboard fixture failure"))
    waitUntil("failed copy restores history") { !value.panel.isConfirmingCopyTransform }
    check(value.panel.window.isVisible && value.search.isEnabled && value.requests.count == 1,
          "a failed write leaves history open and refreshes records changed during transformation")
    value.panel.receive(rows, total: rows.count, offset: 0)
    start()
    pendingResult?(.failure(TextTransformationError.noText))
    waitUntil("failed transformation restores history") { !value.panel.isConfirmingCopyTransform }
    check(copied.count == 1 && value.panel.window.isVisible && value.search.isEnabled,
          "a transformation error writes nothing and leaves the same history available to retry")

    start()
    let cancelledResult = pendingResult!
    let beforeComputeCancellation = cancellations
    escape(value)
    cancelledResult(.success("Cancelled computation"))
    check(cancellations == beforeComputeCancellation + 1 && !value.panel.isConfirmingCopyTransform
          && copied.count == 1 && value.panel.window.isVisible,
          "Escape cancels computation and ignores a late result without closing history")
    start()
    pendingResult?(.success("Cancelled write"))
    waitUntil("pending cancellable write") { copied.count == 2 }
    let cancelledWrite = pendingCopy!
    let beforeWriteCancellation = cancellations
    escape(value)
    cancelledWrite(nil)
    check(cancellations == beforeWriteCancellation + 1 && !value.panel.isConfirmingCopyTransform
          && value.panel.window.isVisible && value.search.isEnabled,
          "Escape invalidates a pending write and its late success cannot close history")
    start()
    let closedResult = pendingResult!
    let beforeCloseCancellation = cancellations
    value.panel.close(restoreFocus: false)
    closedResult(.success("Closed computation"))
    check(cancellations == beforeCloseCancellation + 1 && copied.count == 2
          && !value.panel.isConfirmingCopyTransform,
          "closing history cancels computation and ignores its late transformed result")

    let success = PanelHarness(rows: rows)
    defer { success.panel.close(restoreFocus: false); success.finish() }
    success.panel.requestCopyTransformOperations = { _, completion in completion(.success(offered)) }
    var successfulSource: Int64?
    var successfulText: String?
    var successfulCompletion: ((Error?) -> Void)?
    success.panel.requestCopyTransform = { id, operation, completion in
        successfulSource = id
        completion(.success("Direct menu result"))
    }
    success.panel.onCopyTransformed = { id, text, completion in
        successfulText = text; successfulCompletion = completion
    }
    var closed = false
    success.panel.onClose = { closed = true }
    choose(menu(success, at: 1), .text(.plainText))
    waitUntil("copy from another card") { successfulCompletion != nil }
    check(successfulSource == 2 && success.panel.selected?.id == 2 && successfulText == "Direct menu result",
          "a nonselected card's submenu copies that card instead of the previous selection")
    successfulCompletion?(nil)
    waitUntil("successful transformed copy closes history") { closed }
    check(!success.panel.isConfirmingCopyTransform && success.panel.window.attachedSheet == nil,
          "successful transformed copying follows the normal history-close path")

    let closingWrite = PanelHarness(rows: rows)
    defer { closingWrite.finish() }
    closingWrite.panel.requestCopyTransformOperations = { _, completion in completion(.success(offered)) }
    closingWrite.panel.requestCopyTransform = { _, _, completion in completion(.success("Closing write")) }
    var writeAfterClose: ((Error?) -> Void)?
    var closeCancellations = 0
    var closeCount = 0
    closingWrite.panel.onCopyTransformed = { _, _, completion in writeAfterClose = completion }
    closingWrite.panel.onCancelCopyTransformed = { closeCancellations += 1 }
    closingWrite.panel.onClose = { closeCount += 1 }
    choose(menu(closingWrite), .text(.plainText))
    waitUntil("write pending before close") { writeAfterClose != nil }
    closingWrite.panel.close(restoreFocus: false)
    writeAfterClose?(nil)
    check(closeCancellations == 1 && closeCount == 1 && !closingWrite.panel.isConfirmingCopyTransform,
          "closing history cancels a pending write and ignores its late successful completion")

    let unsupported = ClipSummary(id: 2, date: Date(), kind: .file, title: "Fixture file", text: "",
                                  source: "Panel Fixture App", byteCount: 0)
    let changingSelection = PanelHarness(rows: [fixture(1), unsupported])
    defer { changingSelection.panel.close(restoreFocus: false); changingSelection.finish() }
    var availabilityCalls = 0
    var delayedAvailability: ((Result<[CopyTransformOperation], Error>) -> Void)?
    changingSelection.panel.requestCopyTransformOperations = { _, completion in
        availabilityCalls += 1; delayedAvailability = completion
    }
    _ = menu(changingSelection)
    changingSelection.panel.move(1)
    check(changingSelection.panel.selected?.id == 2 && delayedAvailability != nil,
          "availability may still be loading when selection moves to an unsupported file")
    delayedAvailability?(.success(offered))
    changingSelection.panel.move(-1)
    let returnedMenu = menu(changingSelection)
    check(availabilityCalls == 1
          && returnedMenu.items.compactMap { $0.representedObject as? CopyTransformOperation } == offered,
          "returning from an unsupported record reuses completed availability without getting stuck loading")

    let hidden = ClipSummary(id: 7, date: Date(), kind: .text, title: "Hidden", text: "", source: "Panel Fixture App",
                             byteCount: 20, isConcealed: true)
    check(!ClipCardAction.copyDifferently.isAvailable(for: hidden)
          && CopyTransformOperation.available(for: hidden).isEmpty,
          "concealed records cannot expose their content through copy transformations")
}
copyTransformChecks()

print("\(checkCount) history panel checks passed")
