import AppKit
import BufferaCore
import BufferaLocalization

func historyResetChecks() {
    let suite = "Buffera.HistoryResetChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let savedMode = UserDefaults.standard.object(forKey: "historyAppearance.mode")
    UserDefaults.standard.set("floating", forKey: "historyAppearance.mode")
    defer {
        defaults.removePersistentDomain(forName: suite)
        if let savedMode { UserDefaults.standard.set(savedMode, forKey: "historyAppearance.mode") }
        else { UserDefaults.standard.removeObject(forKey: "historyAppearance.mode") }
    }
    check(HistoryResetPreferences.load(from: defaults) == HistoryResetPreferences(), "reset defaults to enabled after one minute")
    for invalid: Any in [true, "5", 1.5] {
        defaults.set(invalid, forKey: "historyReset.minutes")
        check(HistoryResetPreferences.load(from: defaults).minutes == 1, "invalid reset duration falls back to one minute")
    }
    defaults.set(-5, forKey: "historyReset.minutes")
    check(HistoryResetPreferences.load(from: defaults).minutes == 1, "reset interval cannot be negative")
    defaults.set(9000, forKey: "historyReset.minutes")
    check(HistoryResetPreferences.load(from: defaults).minutes == 1440, "reset interval is bounded to one day")
    HistoryResetPreferences(isEnabled: false, minutes: 7).save(to: defaults)
    check(HistoryResetPreferences.load(from: defaults) == HistoryResetPreferences(isEnabled: false, minutes: 7),
          "reset toggle and custom duration survive reloading")
    HistoryResetPreferences().save(to: defaults)

    var now = Date(timeIntervalSince1970: 1_700_000_000)
    let clips = (1...320).map(fixture)
    let harness = PanelHarness(rows: clips, resetDefaults: defaults, currentDate: { now })
    defer { harness.finish() }
    let views = descendants(of: harness.panel.window.contentView!)
    let filters = views.compactMap { $0 as? HistoryFilters }.first!
    let scope = views.compactMap { $0 as? NSSegmentedControl }.first!
    harness.panel.setSources(["Panel Fixture App"])
    let buttons = descendants(of: filters.sidebar).compactMap { $0 as? NSButton }
    buttons.first { $0.title == L10n.text("Текст") }!.performClick(nil)
    buttons.first { $0.title == "Panel Fixture App" }!.performClick(nil)
    scope.selectedSegment = 1
    _ = NSApp.sendAction(scope.action!, to: scope.target, from: scope)
    harness.panel.receive(clips, total: clips.count, offset: 0)
    harness.panel.move(190)
    let selectedID = harness.panel.selected?.id
    harness.panel.close(restoreFocus: false)
    now.addTimeInterval(59)
    harness.panel.open(fromShortcut: true)
    let retained = harness.requests.last!
    check(retained.query == "fixture" && retained.filter.favoritesOnly && retained.filter.kind == .text
          && retained.filter.source == "Panel Fixture App" && retained.limit >= clips.count,
          "reopening before the deadline retains search, filters, favorites and deep pagination")
    harness.panel.receive(clips, total: clips.count, offset: 0)
    check(harness.panel.selected?.id == selectedID, "reopening before the deadline retains the selected record")
    now.addTimeInterval(1000)
    harness.panel.open()
    check(harness.requests.last?.query == "fixture", "an open window does not expire after its earlier close")
    harness.panel.receive(clips, total: clips.count, offset: 0)
    harness.panel.close(restoreFocus: false)
    now.addTimeInterval(60)
    harness.panel.clipboardDidCapture(id: 999)
    let requestsBefore = harness.requests.count
    harness.panel.open(fromShortcut: true)
    let reset = harness.requests.last!
    check(harness.requests.count == requestsBefore + 1 && reset.query.isEmpty && !reset.filter.favoritesOnly
          && reset.filter.kind == nil && reset.filter.source == nil && reset.filter.from == nil
          && reset.filter.until == nil && reset.limit == 150,
          "at the deadline reopening requests only the first page of unfiltered history")
    harness.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    check(harness.panel.selected?.id == clips.first?.id && harness.cards.selectedIndex == 0,
          "expired state selects the first row without restoring a retained selection or capture hint")
    check(harness.confirmations.isEmpty, "automatic reset never confirms or copies a record")

    harness.search.stringValue = "keep me"
    harness.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: harness.search))
    harness.panel.receive(clips, total: clips.count, offset: 0)
    harness.panel.move(5)
    let customID = harness.panel.selected?.id
    harness.panel.close(restoreFocus: false)
    HistoryResetPreferences(isEnabled: false, minutes: 1).save(to: defaults)
    now.addTimeInterval(500)
    harness.panel.open()
    harness.panel.receive(clips, total: clips.count, offset: 0)
    check(harness.search.stringValue == "keep me" && harness.panel.selected?.id == customID,
          "disabling reset while hidden preserves state beyond the old deadline")
    HistoryResetPreferences(minutes: 3).save(to: defaults)
    harness.panel.close(restoreFocus: false)
    now.addTimeInterval(179)
    harness.panel.close(restoreFocus: false)
    now.addTimeInterval(1)
    harness.panel.open()
    check(harness.search.stringValue.isEmpty, "custom duration applies live and repeated hidden closes do not restart it")

    harness.search.stringValue = "neighbors"
    harness.panel.refresh()
    harness.panel.receive(clips, total: clips.count, offset: 0)
    harness.panel.showNearby(id: clips[4].id)
    harness.panel.close(restoreFocus: false)
    now.addTimeInterval(180)
    harness.panel.open()
    check(!harness.panel.isShowingNearby && harness.requests.last?.query == "",
          "expired nearby return state opens ordinary history with no saved query")

    harness.panel.receive(clips, total: clips.count, offset: 0)
    harness.panel.move(190)
    harness.panel.close(restoreFocus: false)
    now.addTimeInterval(180)
    harness.panel.openSource(clips[8])
    check(harness.panel.isShowingNearby, "an explicit chat source still opens after navigation expires")
    harness.panel.returnFromNearby()
    harness.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    check(harness.panel.selected?.id == clips.first?.id && harness.requests.last?.query == "",
          "returning from a chat source cannot resurrect an expired selection")
}
