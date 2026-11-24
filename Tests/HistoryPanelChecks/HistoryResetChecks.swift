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
    check(HistoryPromotionPreferences.shouldDefer(isOnFirstScreen: true, in: defaults)
          && !HistoryPromotionPreferences.shouldDefer(isOnFirstScreen: false, in: defaults),
          "default promotion defers first-screen clips and immediately promotes deep clips")
    HistoryPromotionPreferences.setEnabled(false, in: defaults)
    check(!HistoryPromotionPreferences.shouldDefer(isOnFirstScreen: true, in: defaults),
          "turning off deferment immediately promotes first-screen clips too")
    check(HistoryResetPreferences.load(from: defaults) == HistoryResetPreferences(),
          "promotion preference does not change reset settings")
    HistoryPromotionPreferences.setEnabled(true, in: defaults)
    check(HistoryPromotionPreferences.isEnabled(in: defaults), "deferred promotion can be restored")

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
    defaults.removeObject(forKey: "historyReset.timing")
    check(HistoryResetPreferences.load(from: defaults) == HistoryResetPreferences(isEnabled: false, minutes: 7),
          "existing preferences without a timing mode retain their enabled flag and delay")
    for invalid: Any in ["unknown", true, 5] {
        defaults.set(invalid, forKey: "historyReset.timing")
        check(HistoryResetPreferences.load(from: defaults).timing == .afterDelay,
              "unknown or malformed reset timing falls back to the existing delayed mode")
    }
    let immediate = HistoryResetPreferences(minutes: 7, timing: .immediately)
    immediate.save(to: defaults)
    check(HistoryResetPreferences.load(from: defaults) == immediate,
          "immediate mode persists without discarding the custom delay")
    let closed = Date(timeIntervalSince1970: 1_700_000_000)
    check(immediate.shouldReset(closedAt: closed, now: closed) && !immediate.shouldReset(closedAt: nil, now: closed),
          "immediate timing needs a closed window but no elapsed delay")
    check(!HistoryResetPreferences(isEnabled: false, timing: .immediately).shouldReset(closedAt: closed, now: closed),
          "the reset checkbox disables immediate mode too")
    HistoryResetPreferences().save(to: defaults)

    var now = Date(timeIntervalSince1970: 1_700_000_000)
    let clips = (1...320).map(fixture)
    let harness = PanelHarness(rows: clips, resetDefaults: defaults, currentDate: { now })
    defer { harness.finish() }
    var promotion = HistoryUsePromotion()
    promotion.recordUse(id: clips[1].id, deferred: true)
    promotion.recordUse(id: clips[190].id, deferred: false)
    check(promotion.takePending() == nil, "immediate promotion supersedes an older pending clip")
    promotion.recordUse(id: clips[1].id, deferred: true)
    promotion.recordUse(id: clips[2].id, deferred: true)
    var promoted: [Int64] = []
    var requestCountAtReset: Int?
    harness.panel.onHistoryReset = { [unowned harness] in
        requestCountAtReset = harness.requests.count
        if let id = promotion.takePending() { promoted.append(id) }
    }
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
    check(promoted.isEmpty, "reopening before the deadline leaves the promotion pending")
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
    check(promoted == [clips[2].id] && requestCountAtReset == requestsBefore,
          "delayed reset promotes the latest pending clip before requesting the default list")
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
    promotion.recordUse(id: clips[3].id, deferred: true)
    harness.panel.close(restoreFocus: false)
    HistoryResetPreferences(isEnabled: false, minutes: 1).save(to: defaults)
    now.addTimeInterval(500)
    harness.panel.open()
    harness.panel.receive(clips, total: clips.count, offset: 0)
    check(harness.search.stringValue == "keep me" && harness.panel.selected?.id == customID,
          "disabling reset while hidden preserves state beyond the old deadline")
    check(promoted == [clips[2].id], "disabled automatic reset keeps promotion pending")
    let resetButton = views.compactMap { $0 as? NSButton }.first {
        $0.toolTip == L10n.text("Вся история · ⌘0")
    }!
    let requestsBeforeManualReset = harness.requests.count
    resetButton.performClick(nil)
    check(promoted == [clips[2].id, clips[3].id] && requestCountAtReset == requestsBeforeManualReset,
          "manual reset promotes before requesting history even with automatic reset disabled")
    harness.panel.receive(clips, total: clips.count, offset: 0)
    harness.search.stringValue = "custom delay"
    harness.panel.refresh()
    harness.panel.receive(clips, total: clips.count, offset: 0)
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

    groupedFirstScreenChecks()
    immediateHistoryResetChecks(defaults: defaults)
}

private func groupedFirstScreenChecks() {
    let harness = PanelHarness()
    defer { harness.finish() }
    let clips = (1...30).map(fixture)
    let tile = GroupTile(title: "Fixture", isFile: false, image: NSImage(size: NSSize(width: 8, height: 8)))
    harness.panel.requestGroupTiles = { _, done in done([tile, tile]) }
    harness.cards.columns = 1
    harness.cards.visibleRows = 3
    harness.cards.sizesToContent = true
    harness.search.stringValue = ""
    harness.panel.refresh()
    harness.panel.receive(clips, total: clips.count, offset: 0)
    harness.panel.window.contentView?.layoutSubtreeIfNeeded()
    let visible = clips.map { harness.panel.isOnFirstHistoryScreen(id: $0.id) }
    check(visible.first == true && visible.last == false, "group fixture spans the first screen")
    let textOnly = clips.indices.map { index in
        harness.cards.isOnFirstScreen(at: index, count: clips.count) { row, width, maximumHeight in
            ClipCardView.preferredHeight(for: clips[row], revealedText: nil, width: width, maximumHeight: maximumHeight)
        }
    }
    check(textOnly != visible, "treating groups as short text changes the promotion boundary")
    harness.panel.unfilteredHistoryPrefix = clips
    harness.search.stringValue = "fixture"
    check(clips.map { harness.panel.isOnFirstHistoryScreen(id: $0.id) } == visible,
          "filtered promotion accounts for full-height group cards above the selected clip")
}

private func immediateHistoryResetChecks(defaults: UserDefaults) {
    let clips = (1...320).map(fixture)
    HistoryResetPreferences(minutes: 12, timing: .immediately).save(to: defaults)
    let immediate = PanelHarness(rows: clips, resetDefaults: defaults)
    defer { immediate.finish() }
    var promotion = HistoryUsePromotion()
    promotion.recordUse(id: clips[2].id, deferred: true)
    var promotedID: Int64?
    var requestCountAtReset: Int?
    immediate.panel.onHistoryReset = { [unowned immediate] in
        requestCountAtReset = immediate.requests.count
        promotedID = promotion.takePending()
    }
    let views = descendants(of: immediate.panel.window.contentView!)
    let filters = views.compactMap { $0 as? HistoryFilters }.first!
    let scope = views.compactMap { $0 as? NSSegmentedControl }.first!
    immediate.panel.setSources(["Panel Fixture App"])
    let buttons = descendants(of: filters.sidebar).compactMap { $0 as? NSButton }
    buttons.first { $0.title == L10n.text("Текст") }!.performClick(nil)
    buttons.first { $0.title == "Panel Fixture App" }!.performClick(nil)
    scope.selectedSegment = 1
    _ = NSApp.sendAction(scope.action!, to: scope.target, from: scope)
    immediate.panel.receive(clips, total: clips.count, offset: 0)
    immediate.panel.move(190)
    let selectedID = immediate.panel.selected?.id
    check(!immediate.panel.open() && immediate.search.stringValue == "fixture" && scope.selectedSegment == 1,
          "immediate reset never clears an already open window")
    immediate.panel.receive(clips, total: clips.count, offset: 0)
    check(immediate.panel.selected?.id == selectedID, "opening an already visible window retains its selection")

    let requestsBeforeClose = immediate.requests.count
    immediate.panel.close(restoreFocus: false)
    check(promotedID == clips[2].id && requestCountAtReset == requestsBeforeClose,
          "immediate reset promotes the pending clip before preparing hidden history")
    let request = immediate.requests.last!
    check(request.query.isEmpty && !request.filter.favoritesOnly && request.filter.kind == nil
          && request.filter.source == nil && request.limit == 150 && scope.selectedSegment == 0
          && !filters.hasActiveFilters && immediate.panel.isPreparingHiddenHistory && !immediate.panel.window.isVisible,
          "immediate close prepares the first page of all history with query, filters and favorites cleared")
    immediate.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    immediate.panel.close(restoreFocus: false)
    immediate.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    let preparedRequests = immediate.requests.count
    check(immediate.panel.open(fromShortcut: true), "an immediate reset is reported even after a redundant hidden close")
    check(immediate.requests.count == preparedRequests && immediate.panel.window.isVisible
          && immediate.panel.selected?.id == clips.first?.id && immediate.cards.selectedIndex == 0
          && immediate.cards.scrollView.contentView.bounds.origin.y == 0,
          "immediate reopening reuses prepared default cards and starts at the first record without requerying")
    immediate.panel.window.onFlagsChanged?([])
    check(immediate.confirmations.isEmpty, "immediate reset does not copy a record")

    immediate.search.stringValue = "waiting"
    immediate.panel.refresh()
    immediate.panel.receive(clips, total: clips.count, offset: 0)
    immediate.panel.close(restoreFocus: false)
    let pendingRequests = immediate.requests.count
    immediate.panel.open()
    check(!immediate.panel.window.isVisible && immediate.requests.count == pendingRequests,
          "reopening during immediate preparation waits for the existing default query")
    immediate.panel.close(restoreFocus: false)
    immediate.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    check(!immediate.panel.window.isVisible, "a late immediate-reset result cannot present a cancelled opening")
    let cancelledRequests = immediate.requests.count
    immediate.panel.open()
    check(immediate.panel.window.isVisible && immediate.requests.count == cancelledRequests,
          "a cancelled opening can reuse its completed hidden default preparation")

    immediate.panel.close(restoreFocus: false)
    immediate.panel.searchFailed(HistoryError.database("Immediate preparation fixture failure"))
    let failedRequests = immediate.requests.count
    immediate.panel.open()
    check(immediate.requests.count == failedRequests + 1 && immediate.requests.last?.query == ""
          && !immediate.panel.window.isVisible,
          "failed immediate preparation retries the default query on opening")
    immediate.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    immediate.panel.move(30)
    immediate.panel.close(restoreFocus: false)
    immediate.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    immediate.panel.openSource(clips[8])
    check(immediate.panel.isShowingNearby, "an explicit chat source still opens after immediate reset")
    immediate.panel.returnFromNearby()
    immediate.panel.receive(Array(clips.prefix(150)), total: clips.count, offset: 0)
    check(immediate.panel.selected?.id == clips.first?.id && immediate.requests.last?.query == "",
          "returning from a chat source preserves the immediate reset instead of resurrecting the old selection")

    HistoryResetPreferences(isEnabled: false, minutes: 12, timing: .immediately).save(to: defaults)
    let disabled = PanelHarness(rows: Array(clips.prefix(10)), resetDefaults: defaults)
    defer { disabled.finish() }
    disabled.panel.move(5)
    disabled.panel.close(restoreFocus: false)
    disabled.panel.receive(Array(clips.prefix(10)), total: 10, offset: 0)
    let disabledRequests = disabled.requests.count
    check(!disabled.panel.open() && disabled.search.stringValue == "fixture"
          && disabled.panel.selected?.id == clips[5].id && disabled.requests.count == disabledRequests,
          "disabling immediate reset retains the previous search and selection on prepared reopening")

    HistoryResetPreferences(minutes: 12).save(to: defaults)
    disabled.panel.close(restoreFocus: false)
    disabled.panel.receive(Array(clips.prefix(10)), total: 10, offset: 0)
    let beforeModeChange = disabled.requests.count
    HistoryResetPreferences(minutes: 12, timing: .immediately).save(to: defaults)
    check(disabled.panel.open() && disabled.search.stringValue.isEmpty
          && disabled.requests.count == beforeModeChange + 1 && disabled.requests.last?.limit == 150,
          "enabling immediate reset while hidden discards the previously prepared filtered state")
    disabled.panel.receive(Array(clips.prefix(10)), total: 10, offset: 0)
    check(disabled.panel.selected?.id == clips.first?.id, "a hidden change to immediate mode selects the first record")
}
