import AppKit
import BufferaCore

// Run from the repository root. The windows are fully transparent; no
// clipboard, database, or app activation are used. Appearance checks restore
// every preference they touch before asserting their results.
// mkdir -p .build/history-panel-checks
// swiftc -emit-library -emit-module -module-name BufferaCore Sources/BufferaCore/Clip.swift -emit-module-path .build/history-panel-checks/BufferaCore.swiftmodule -o .build/history-panel-checks/libBufferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I .build/history-panel-checks -L .build/history-panel-checks -lBufferaCore -Xlinker -rpath -Xlinker "$PWD/.build/history-panel-checks" -module-cache-path .build/ModuleCache Sources/Buffera/HistoryPanel.swift Sources/Buffera/HistoryCardsView.swift Sources/Buffera/ClipCardView.swift Sources/Buffera/HistoryFilters.swift Sources/Buffera/HistoryAppearance.swift Sources/Buffera/BrandIdentity.swift Sources/Buffera/LegacyMigration.swift Sources/Buffera/ClipPreview.swift Sources/Buffera/ClipboardService.swift Tests/HistoryPanelChecks/main.swift -o .build/history-panel-checks/checks
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
    struct Request { let query: String; let offset: Int; let limit: Int; let silent: Bool }
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
                                         silent: self.panel.isRefreshingSearchIndex))
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

print("\(checkCount) history panel checks passed")
