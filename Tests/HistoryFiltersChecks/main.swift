import AppKit
import BufferaCore

// Synthetic controls and an offscreen, never-shown layout fixture only.
// No clipboard, user history, preferences, or application activation are used.
// mkdir -p .build/history-filters-checks
// swiftc -emit-library -emit-module -module-name BufferaCore Sources/BufferaCore/Clip.swift -emit-module-path .build/history-filters-checks/BufferaCore.swiftmodule -o .build/history-filters-checks/libBufferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I .build/history-filters-checks -L .build/history-filters-checks -lBufferaCore -Xlinker -rpath -Xlinker "$PWD/.build/history-filters-checks" -module-cache-path .build/ModuleCache Sources/Buffera/HistoryFilters.swift Sources/Buffera/BrandIdentity.swift Sources/Buffera/LegacyMigration.swift Tests/HistoryFiltersChecks/main.swift -o .build/history-filters-checks/checks
// .build/history-filters-checks/checks

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
    checkCount += 1
    print("PASS", message)
}

func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

func row(_ title: String, in view: NSView) -> NSButton {
    descendants(of: view).compactMap { $0 as? NSButton }.first { $0.title == title }!
}

func invoke(_ item: NSMenuItem) {
    check(NSApp.sendAction(item.action!, to: item.target, from: item), "menu action is connected: \(item.title)")
}

func snapshot(_ filters: HistoryFilters) -> SearchFilter {
    var filter = SearchFilter(); filters.apply(to: &filter); return filter
}

func typeMenu(_ filters: HistoryFilters) -> NSMenu {
    filters.makeFilterMenu().items.first {
        $0.submenu?.items.contains(where: { $0.title == "Все типы" }) == true
    }!.submenu!
}

func typeItem(_ title: String, in filters: HistoryFilters) -> NSMenuItem {
    typeMenu(filters).items.first { $0.title == title }!
}

func checkType(_ title: String, in filters: HistoryFilters) {
    let filter = snapshot(filters)
    let expectedKind = ClipKind.allCases.first { $0.label == title }
    check(filter.kind == expectedKind && filter.remoteOnly == (title == "С устройств") && filter.concealedOnly == (title == "Скрытые"),
          "\(title) is the only type constraint in the search filter")
    let typeTitles = ["Все типы"] + ClipKind.allCases.map(\.label) + ["С устройств", "Скрытые"]
    check(typeTitles.filter { row($0, in: filters.sidebar).state == .on } == [title]
          && typeMenu(filters).items.filter { $0.state == .on }.map(\.title) == [title],
          "sidebar and toolbar menu select only \(title)")
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let filters = HistoryFilters(frame: .zero)
let toolbar = filters.subviews.compactMap { $0 as? NSButton }.first!
let remote = row("С устройств", in: filters.sidebar)
let concealed = row("Скрытые", in: filters.sidebar)
var changes = 0
filters.onChange = { changes += 1 }

check(remote.image != nil && concealed.image != nil, "both additional type symbols are available")
check(!filters.hasActiveFilters && !snapshot(filters).remoteOnly && !snapshot(filters).concealedOnly,
      "types start unfiltered")
checkType("Все типы", in: filters)
check(remote.superview === row("Картинка", in: filters.sidebar).superview && concealed.superview === remote.superview,
      "device and hidden types belong to the same sidebar stack as content types")
check(!descendants(of: filters.sidebar).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Категории" },
      "sidebar has no separate category heading")
check(!filters.makeFilterMenu().items.contains { ["С устройств", "Скрытые"].contains($0.title) },
      "device and hidden types are inside the type submenu rather than independent menu toggles")
remote.performClick(nil)
check(snapshot(filters).remoteOnly && !snapshot(filters).concealedOnly && changes == 1,
      "sidebar device type changes the search filter once")
check(filters.hasActiveFilters && remote.state == .on && toolbar.toolTip!.contains("С устройств"),
      "device type updates sidebar selection and toolbar summary")
check(toolbar.contentTintColor == BrandIdentity.accentColor, "active type gives the toolbar its active tint")
checkType("С устройств", in: filters)

invoke(typeItem("Скрытые", in: filters))
check(!snapshot(filters).remoteOnly && snapshot(filters).concealedOnly && changes == 2 && concealed.state == .on,
      "hidden type replaces the device type through the toolbar menu")
checkType("Скрытые", in: filters)
check(filters.makeFilterMenu().items.contains { $0.title == "Тип: Скрытые" },
      "type submenu title reflects the hidden type")
concealed.performClick(nil)
checkType("Скрытые", in: filters)
invoke(typeItem("Скрытые", in: filters))
checkType("Скрытые", in: filters)

filters.setSources(["Safari", "Notes", "loginwindow", "WindowServer", "Bufera", "Buffera", ""])
let appTitles = filters.makeFilterMenu().items.first { $0.submenu?.items.contains(where: { $0.title == "Все приложения" }) == true }!.submenu!.items.map(\.title)
check(appTitles.contains("Safari") && appTitles.contains("Notes") && !appTitles.contains("loginwindow") && !appTitles.contains("WindowServer") && !appTitles.contains("Buffera") && !appTitles.contains("Bufera"),
      "application menu excludes system processes and Buffera while keeping real apps")
let sidebarTitles = descendants(of: filters.sidebar).compactMap { ($0 as? NSButton)?.title }
check(!sidebarTitles.contains("loginwindow") && !sidebarTitles.contains("WindowServer"),
      "application sidebar also excludes system processes")
row("Картинка", in: filters.sidebar).performClick(nil)
row("Safari", in: filters.sidebar).performClick(nil)
checkType("Картинка", in: filters)
var combined = SearchFilter()
combined.query = "fixture"; combined.favoritesOnly = true
combined.from = Date(timeIntervalSince1970: 1_700_000_000); combined.until = Date(timeIntervalSince1970: 1_700_086_400)
filters.apply(to: &combined)
check(!combined.remoteOnly && !combined.concealedOnly && combined.kind == .image && combined.source == "Safari",
      "content type replaces device and hidden constraints while retaining the app filter")
check(combined.query == "fixture" && combined.favoritesOnly && combined.from != nil && combined.until != nil,
      "type application preserves query, favorites, and date bounds")
remote.performClick(nil)
filters.apply(to: &combined)
check(combined.kind == nil && combined.remoteOnly && !combined.concealedOnly && combined.source == "Safari"
      && combined.query == "fixture" && combined.favoritesOnly
      && combined.from == Date(timeIntervalSince1970: 1_700_000_000) && combined.until == Date(timeIntervalSince1970: 1_700_086_400),
      "switching to devices clears the old content type and preserves independent filters")
filters.dismiss(); filters.setSidebarVisible(false); filters.setSidebarVisible(true)
filters.setSources(["Safari", "Notes"])
check(snapshot(filters).remoteOnly && !snapshot(filters).concealedOnly && snapshot(filters).source == "Safari",
      "closing filter controls, hiding the sidebar, and refreshing sources preserve type and app")

filters.setInteractionEnabled(false)
let beforeDisabled = changes
invoke(typeItem("Скрытые", in: filters))
invoke(typeItem("Картинка", in: filters))
invoke(typeItem("Все типы", in: filters))
concealed.performClick(nil)
check(!remote.isEnabled && !concealed.isEnabled && changes == beforeDisabled && snapshot(filters).remoteOnly,
      "busy sidebar and menu actions cannot change the selected type")
filters.setInteractionEnabled(true)
invoke(typeItem("С устройств", in: filters))
checkType("С устройств", in: filters)
invoke(typeItem("Все типы", in: filters))
checkType("Все типы", in: filters)
check(snapshot(filters).source == "Safari" && filters.hasActiveFilters,
      "all types clears only the type and retains the application filter")
concealed.performClick(nil)
row("Все типы", in: filters.sidebar).performClick(nil)
checkType("Все типы", in: filters)
for kind in ClipKind.allCases {
    remote.performClick(nil)
    invoke(typeItem(kind.label, in: filters))
    checkType(kind.label, in: filters)
    concealed.performClick(nil)
    row(kind.label, in: filters.sidebar).performClick(nil)
    checkType(kind.label, in: filters)
}
concealed.performClick(nil)
invoke(filters.makeFilterMenu().items.first { $0.title == "Сбросить фильтры" }!)
let reset = snapshot(filters)
check(!filters.hasActiveFilters && !reset.remoteOnly && !reset.concealedOnly && reset.kind == nil && reset.source == nil,
      "reset clears the selected type together with the application filter")
check(toolbar.toolTip == "Фильтры" && toolbar.contentTintColor == .secondaryLabelColor && remote.state == .off && concealed.state == .off,
      "reset clears type selections, toolbar summary, and active tint")
checkType("Все типы", in: filters)

let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 170, height: 320),
                      styleMask: .borderless, backing: .buffered, defer: false)
window.alphaValue = 0
let root = window.contentView!
filters.sidebar.frame = root.bounds; filters.sidebar.autoresizingMask = [.width, .height]
root.addSubview(filters.sidebar)
filters.setSources((0..<30).map { "Application \($0)" })
root.layoutSubtreeIfNeeded()
let scroll = descendants(of: filters.sidebar).compactMap { $0 as? NSScrollView }.first!
let document = scroll.documentView!
check(scroll.frame.height == 320 && document.frame.height > scroll.contentSize.height,
      "minimum sidebar height uses a scrolling document rather than compressing rows")
check(descendants(of: document).compactMap { $0 as? NSButton }.allSatisfy { $0.frame.height >= 25 && $0.frame.height <= 28 },
      "all sidebar rows retain usable height with many apps")
check(document.visibleRect.intersects(remote.convert(remote.bounds, to: document)) && document.visibleRect.intersects(concealed.convert(concealed.bounds, to: document)),
      "both additional types are initially reachable with the other content types")
let lastApp = row("Application 29", in: document)
lastApp.scrollToVisible(lastApp.bounds)
root.layoutSubtreeIfNeeded()
check(document.visibleRect.contains(lastApp.convert(lastApp.bounds, to: document)),
      "the last application remains reachable by scrolling at minimum height")
row("Все типы", in: document).scrollToVisible(row("Все типы", in: document).bounds)
root.layoutSubtreeIfNeeded()
check(document.visibleRect.contains(row("Все типы", in: document).convert(row("Все типы", in: document).bounds, to: document)),
      "content types remain reachable after scrolling back up")

print("\(checkCount) history filter checks passed")
