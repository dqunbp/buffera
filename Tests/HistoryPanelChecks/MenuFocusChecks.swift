import AppKit
import BufferaCore

func menuFocusChecks() {
    func flush() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    for favorites in [false, true] {
        for chooseNearby in [false, true] {
            let value = PanelHarness(rows: [fixture(1), fixture(2)])
            defer { value.finish() }
            let panel = value.panel
            let scope = descendants(of: panel.window.contentView!).compactMap { $0 as? NSSegmentedControl }.first!
            scope.selectedSegment = favorites ? 1 : 0
            _ = NSApp.sendAction(scope.action!, to: scope.target, from: scope)
            panel.receive([fixture(1), fixture(2)], total: 2, offset: 0)
            value.cards.layoutSubtreeIfNeeded()
            waitUntil("menu focus card") { value.cards.card(at: 0) != nil }
            let card = value.cards.card(at: 0)!
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let menu = card.menu(for: event)!
            let item = menu.items.first { $0.tag == ClipCardAction.nearby.rawValue }!
            // A global-hotkey panel can still be non-key when its menu opens.
            // Exercise both a queued blur and another blur during menu tracking.
            panel.window.resignKey()
            panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel.window))
            card.menuWillOpen(menu)
            panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel.window))
            card.menuDidClose(menu)
            if chooseNearby { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
            flush()
            check(panel.window.isVisible, "ending a non-key card menu preserves history (favorites=\(favorites), action=\(chooseNearby))")
            check(panel.isShowingNearby == chooseNearby && value.nearbyRequests.count == (chooseNearby ? 1 : 0),
                  "menu choice opens nearby exactly once; cancellation does not navigate")
            check(value.confirmations.isEmpty, "nearby menu and cancellation never copy a record")
            panel.dismissForOutsideInteraction(source: .globalMouse)
            flush()
            check(!panel.window.isVisible, "an outside click after the card menu still closes history")
        }
    }
}
