import AppKit
import BufferaCore

func independentRevealChecks() {
    func secret(_ id: Int) -> ClipSummary {
        ClipSummary(id: Int64(id), date: fixture(id).date, kind: .text, title: "Скрытая запись",
                    text: "", source: "Panel Fixture App", byteCount: 10, isConcealed: true)
    }
    func cardText(_ value: PanelHarness, _ index: Int) -> [String] {
        descendants(of: value.cards.card(at: index)!).compactMap { $0 as? NSTextField }.map(\.stringValue)
    }
    func clickLock(_ value: PanelHarness, _ index: Int) {
        let button = descendants(of: value.cards.card(at: index)!).compactMap { $0 as? NSButton }
            .first { $0.tag == ClipCardAction.reveal.rawValue }!
        button.performClick(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    func deliver(_ value: PanelHarness, _ stored: [ClipSummary]) {
        value.panel.receive(stored, total: stored.count, offset: 0)
    }

    var stored = [secret(1), secret(2), fixture(3)]
    let concurrent = PanelHarness(rows: stored)
    defer { concurrent.panel.close(restoreFocus: false); concurrent.finish() }
    var reveals: [Int64] = []
    var conceals: [Int64] = []
    concurrent.panel.onReveal = { reveals.append($0) }
    concurrent.panel.onConceal = { conceals.append($0) }
    clickLock(concurrent, 0)
    clickLock(concurrent, 0)
    clickLock(concurrent, 1)
    check(reveals == [1, 2], "different cards can unlock concurrently while duplicate writes to the same card are blocked")
    stored[1] = fixture(2)
    concurrent.panel.unconcealFinished(stored[1])
    deliver(concurrent, stored)
    stored[0] = fixture(1)
    concurrent.panel.unconcealFinished(stored[0])
    deliver(concurrent, stored)
    check(cardText(concurrent, 0).contains("Search fixture 1") && cardText(concurrent, 1).contains("Search fixture 2"),
          "out-of-order unlock completions turn both cards into ordinary records")
    check(concurrent.panel.selected?.id == 2, "an unlock completion cannot move the current selection")
    concurrent.cards.select(2, scrollIntoView: false)
    check(cardText(concurrent, 0).contains("Search fixture 1") && cardText(concurrent, 1).contains("Search fixture 2"),
          "ordinary selection does not conceal previously unlocked records")
    clickLock(concurrent, 1)
    check(conceals == [2], "closing the second lock requests a persisted concealment only for that record")
    stored[1] = secret(2)
    concurrent.panel.concealFinished(id: 2)
    deliver(concurrent, stored)
    check(cardText(concurrent, 0).contains("Search fixture 1") && cardText(concurrent, 1).contains("••••••••"),
          "closing the second lock leaves the first record ordinary")
    clickLock(concurrent, 1)
    stored[1] = fixture(2)
    concurrent.panel.unconcealFinished(stored[1])
    deliver(concurrent, stored)
    check(reveals == [1, 2, 2] && cardText(concurrent, 0).contains("Search fixture 1"),
          "unlocking the second record again leaves its neighbor unchanged")
    concurrent.panel.onConceal = { id in
        concurrent.panel.visibilityChangeFailed(HistoryError.database("Conceal fixture failure"), id: id)
    }
    clickLock(concurrent, 2)
    check(cardText(concurrent, 0).contains("Search fixture 1") && cardText(concurrent, 1).contains("Search fixture 2")
          && cardText(concurrent, 2).contains("Search fixture 3"),
          "failed concealment leaves ordinary records and their neighbors unchanged")
    concurrent.panel.close(restoreFocus: false)
    deliver(concurrent, stored)
    concurrent.panel.open()
    deliver(concurrent, stored)
    check(cardText(concurrent, 0).contains("Search fixture 1") && cardText(concurrent, 1).contains("Search fixture 2"),
          "closing and reopening history does not conceal unlocked records")
    let restarted = PanelHarness(rows: stored)
    defer { restarted.panel.close(restoreFocus: false); restarted.finish() }
    check(cardText(restarted, 0).contains("Search fixture 1") && cardText(restarted, 1).contains("Search fixture 2"),
          "a new panel renders unlocked stored summaries as ordinary records without a reveal cache")

    var failedStored = [fixture(1), secret(2), fixture(3)]
    let failing = PanelHarness(rows: failedStored)
    defer { failing.panel.close(restoreFocus: false); failing.finish() }
    var failedRequests: [Int64] = []
    failing.panel.onReveal = { failedRequests.append($0) }
    clickLock(failing, 1)
    failing.panel.visibilityChangeFailed(HistoryError.database("Unlock fixture failure"), id: 2)
    let failedButton = descendants(of: failing.cards.card(at: 1)!).compactMap { $0 as? NSButton }
        .first { $0.tag == ClipCardAction.reveal.rawValue }!
    check(cardText(failing, 0).contains("Search fixture 1") && cardText(failing, 1).contains("••••••••") && failedButton.isEnabled,
          "an unlock error keeps its neighbor ordinary, its own record hidden, and makes retry available")
    clickLock(failing, 1)
    failedStored[1] = fixture(2)
    failing.panel.unconcealFinished(failedStored[1])
    deliver(failing, failedStored)
    check(failedRequests == [2, 2] && cardText(failing, 1).contains("Search fixture 2"),
          "a failed unlock can be retried without reopening history")

    var closedStored = [secret(1), secret(2)]
    let closing = PanelHarness(rows: closedStored)
    defer { closing.panel.close(restoreFocus: false); closing.finish() }
    var closingRequests: [Int64] = []
    closing.panel.onReveal = { closingRequests.append($0) }
    clickLock(closing, 0)
    closing.panel.close(restoreFocus: false)
    deliver(closing, closedStored)
    closing.panel.open()
    deliver(closing, closedStored)
    clickLock(closing, 0)
    check(closingRequests == [1], "closing and reopening cannot submit a second write while the original unlock is pending")
    closing.panel.close(restoreFocus: false)
    closedStored[0] = fixture(1)
    closing.panel.unconcealFinished(closedStored[0])
    deliver(closing, closedStored)
    check(!closing.panel.window.isVisible, "an unlock completing while history is closed cannot reopen the window")
    closing.panel.open()
    deliver(closing, closedStored)
    check(cardText(closing, 0).contains("Search fixture 1") && cardText(closing, 1).contains("••••••••"),
          "a committed unlock completing after close appears as ordinary on the next opening")
    clickLock(closing, 1)
    closing.panel.close(restoreFocus: false)
    closing.panel.visibilityChangeFailed(HistoryError.database("Closed unlock failure"), id: 2)
    deliver(closing, closedStored)
    closing.panel.open()
    deliver(closing, closedStored)
    clickLock(closing, 1)
    check(closingRequests == [1, 2, 2], "an unlock failing while closed releases its pending write for a later retry")

    var pinnedStored = [fixture(1), fixture(2), secret(3)]
    let pinned = PanelHarness(rows: pinnedStored)
    defer { pinned.panel.close(restoreFocus: false); pinned.finish() }
    let pin = descendants(of: pinned.panel.window.contentView!).compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "history.pin" }!
    pin.performClick(nil)
    var pinnedRequests: [Int64] = []
    pinned.panel.onReveal = { pinnedRequests.append($0) }
    clickLock(pinned, 2)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    pinnedStored[2] = fixture(3)
    pinned.panel.unconcealFinished(pinnedStored[2])
    deliver(pinned, pinnedStored)
    check(pinned.panel.window.isVisible && pinnedRequests == [3]
          && (0..<3).allSatisfy { cardText(pinned, $0).contains("Search fixture \($0 + 1)") },
          "external focus loss neither re-conceals ordinary records nor cancels a committed unlock")
}
