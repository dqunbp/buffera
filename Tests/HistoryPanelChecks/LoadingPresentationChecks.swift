import AppKit
import BufferaCore

func loadingPresentationChecks() {
    func type(_ query: String, in value: PanelHarness) {
        value.search.stringValue = query
        value.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: value.search))
    }
    func count(_ value: PanelHarness) -> Int {
        let collection = descendants(of: value.cards).compactMap { $0 as? NSCollectionView }.first!
        return value.cards.collectionView(collection, numberOfItemsInSection: 0)
    }

    let value = PanelHarness(rows: [fixture(1), fixture(2), fixture(3)])
    defer { value.panel.close(restoreFocus: false); value.finish() }
    waitUntil("initial cards") { value.cards.card(at: 0) != nil }
    let originalCard = value.cards.card(at: 0)
    type("new", in: value)
    type("new query", in: value)
    check(count(value) == 3 && value.cards.card(at: 0) === originalCard,
          "successive query edits retain the actual cards until a replacement arrives")
    check(value.panel.selected == nil && descendants(of: originalCard!).compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled },
          "retained search cards cannot act as current results")
    value.cards.onActivate?(0)
    check(value.search.isEnabled && value.confirmations.isEmpty,
          "double-clicking a retained card cannot queue copying a different search result")
    var deleted: [Int64] = []
    value.panel.onDelete = { deleted.append($0) }
    let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
        windowNumber: value.panel.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: 51)!
    _ = value.panel.window.onKeyDown?(delete)
    check(deleted.isEmpty, "keyboard deletion cannot target a retained result during search")
    value.panel.move(1)
    value.enter()
    check(value.confirmations.isEmpty && count(value) == 3, "Enter waits without removing the retained cards")
    value.panel.receive([fixture(10), fixture(11)], total: 2, offset: 0)
    check(value.confirmations == [11] && count(value) == 2,
          "queued navigation and Enter use the replacement results")

    let empty = PanelHarness(rows: [fixture(1)])
    defer { empty.panel.close(restoreFocus: false); empty.finish() }
    type("missing", in: empty)
    empty.panel.receive([], total: 0, offset: 0)
    check(count(empty) == 0 && empty.panel.selected == nil, "a completed empty search removes old results")
    empty.panel.receive([fixture(1)], total: 1, offset: 0)
    type("failure", in: empty)
    empty.enter()
    empty.panel.searchFailed(HistoryError.database("Fixture query failure"))
    check(count(empty) == 0 && empty.search.isEnabled && empty.confirmations.isEmpty,
          "query failure clears stale results and cancels pending confirmation")
    type("retry", in: empty)
    empty.panel.receive([fixture(2)], total: 1, offset: 0)
    check(empty.panel.selected?.id == 2, "search can recover after a failed replacement")

    empty.panel.close(restoreFocus: false)
    empty.panel.open(fromShortcut: true)
    check(empty.panel.window.isVisible && count(empty) == 1,
          "hotkey reopening keeps the previous cards visible during its fresh query")
    empty.panel.receive([fixture(3)], total: 1, offset: 0)
    empty.panel.window.onFlagsChanged?([])
    check(empty.panel.selected?.id == 3 && empty.confirmations.isEmpty,
          "one hotkey tap still leaves the refreshed panel open")

    let cold = PanelHarness()
    defer { cold.panel.close(restoreFocus: false); cold.finish() }
    cold.panel.close(restoreFocus: false)
    cold.panel.open(fromShortcut: true)
    check(!cold.panel.window.isVisible && cold.panel.isAvailableForShortcut && cold.requests.count == 1,
          "cold hotkey opening starts loading before displaying an empty window")
    cold.panel.shortcutPressed(1, fromGlobalShortcut: true)
    cold.panel.window.onFlagsChanged?([])
    check(!cold.panel.window.isVisible && cold.confirmations.isEmpty,
          "cold hotkey cycling queues confirmation without exposing an empty panel")
    cold.panel.receive([fixture(20), fixture(21)], total: 2, offset: 0)
    check(cold.panel.window.isVisible && count(cold) == 2 && cold.cards.card(at: 1) != nil && cold.confirmations == [21],
          "cold opening presents populated cards before confirming the queued choice")

    let cancelled = PanelHarness()
    defer { cancelled.panel.close(restoreFocus: false); cancelled.finish() }
    cancelled.panel.close(restoreFocus: false)
    cancelled.panel.open(fromShortcut: true)
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    cancelled.panel.observeMouseDown(click, source: .globalMouse)
    cancelled.panel.receive([fixture(1)], total: 1, offset: 0)
    check(!cancelled.panel.window.isVisible && !cancelled.panel.isAvailableForShortcut,
          "an outside click cancels cold presentation and ignores its late result")
    cancelled.panel.open()
    cancelled.panel.searchFailed(HistoryError.database("Fixture cold query failure"))
    check(cancelled.panel.window.isVisible && cancelled.search.isEnabled,
          "cold query errors present a usable window instead of leaving opening pending")
    cancelled.panel.close(restoreFocus: false)
    cancelled.panel.open()
    cancelled.panel.receive([], total: 0, offset: 0)
    check(cancelled.panel.window.isVisible && count(cancelled) == 0,
          "genuinely empty history still opens after the query finishes")

    let pinned = PanelHarness()
    defer { pinned.panel.close(restoreFocus: false); pinned.finish() }
    let pin = descendants(of: pinned.panel.window.contentView!).compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "history.pin" }!
    pin.performClick(nil)
    pinned.panel.close(restoreFocus: false)
    pinned.panel.open(fromShortcut: true)
    pinned.panel.observeMouseDown(click, source: .globalMouse)
    check(pinned.panel.isPinned && pinned.panel.isAvailableForShortcut && !pinned.panel.window.isVisible,
          "pinning protects cold presentation from outside-click dismissal")
    pinned.panel.receive([fixture(1)], total: 1, offset: 0)
    check(pinned.panel.window.isVisible, "a pinned cold opening still presents its loaded cards")

    let confirming = PanelHarness(rows: [fixture(1)])
    defer { confirming.panel.close(restoreFocus: false); confirming.finish() }
    confirming.enter()
    confirming.panel.refresh(preservingSelection: true)
    check(count(confirming) == 0, "a content mutation discards old cards even while confirmation blocks requerying")
    confirming.panel.close(restoreFocus: false)
    confirming.panel.open(fromShortcut: true)
    check(!confirming.panel.window.isVisible, "a mutation during confirmation cannot leave a stale snapshot for reopening")

    let invalidated = PanelHarness(rows: [fixture(1)])
    defer { invalidated.panel.close(restoreFocus: false); invalidated.finish() }
    invalidated.panel.close(restoreFocus: false)
    let requests = invalidated.requests.count
    invalidated.panel.refresh(preservingSelection: true)
    check(count(invalidated) == 0 && invalidated.requests.count == requests,
          "content invalidation while hidden discards the snapshot without launching a query")
    invalidated.panel.open(fromShortcut: true)
    check(!invalidated.panel.window.isVisible,
          "reopening after content invalidation never flashes the discarded snapshot")
}
