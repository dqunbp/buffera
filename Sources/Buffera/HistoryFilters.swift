import BufferaLocalization
import AppKit
import BufferaCore

enum HistoryDateFilter {
    case all, today, yesterday, week, month, range(Date, Date)

    var title: String {
        switch self {
        case .all: return L10n.text("Дата")
        case .today: return L10n.text("Сегодня")
        case .yesterday: return L10n.text("Вчера")
        case .week: return L10n.text("7 дней")
        case .month: return L10n.text("30 дней")
        case .range(let start, let end):
            let format = DateFormatter(); format.locale = L10n.locale
            format.setLocalizedDateFormatFromTemplate("d MMM")
            return "\(format.string(from: min(start, end))) – \(format.string(from: max(start, end)))"
        }
    }

    func apply(to filter: inout SearchFilter) {
        let calendar = Calendar.current; let today = calendar.startOfDay(for: Date())
        switch self {
        case .all: break
        case .today: filter.from = today
        case .yesterday: filter.from = calendar.date(byAdding: .day, value: -1, to: today); filter.until = today
        case .week: filter.from = calendar.date(byAdding: .day, value: -6, to: today)
        case .month: filter.from = calendar.date(byAdding: .day, value: -29, to: today)
        case .range(let start, let end):
            filter.from = calendar.startOfDay(for: min(start, end))
            filter.until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end)))
        }
    }

    var isActive: Bool { if case .all = self { return false }; return true }
}

private final class SidebarFilterRow: NSButton {
    let value: String?
    var selected = false { didSet { updateAppearance() } }
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, image: NSImage?, value: String?) {
        self.value = value
        super.init(frame: .zero)
        self.title = title; self.image = image
        alignment = .left; imagePosition = .imageLeading; imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 12); isBordered = false
        cell?.lineBreakMode = .byTruncatingTail
        toolTip = title
        wantsLayer = true; layer?.cornerRadius = 5
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 25).isActive = true
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    private func updateAppearance() {
        state = selected ? .on : .off
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = selected ? BrandIdentity.accentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
        }
        contentTintColor = selected ? BrandIdentity.accentColor : .labelColor
    }
}

private final class SidebarSourceList: NSStackView {
    override var isFlipped: Bool { true }
}

private final class SidebarDocument: NSView {
    override var isFlipped: Bool { true }
}

private enum HistoryContentType: Equatable {
    case kind(ClipKind), remote, concealed

    static var choices: [Self] { ClipKind.allCases.map(Self.kind) + [.remote, .concealed] }
    init?(value: String?) {
        guard let value else { return nil }
        if let kind = ClipKind(rawValue: value) { self = .kind(kind) }
        else if value == "remote" { self = .remote }
        else if value == "concealed" { self = .concealed }
        else { return nil }
    }
    var value: String {
        switch self {
        case .kind(let kind): return kind.rawValue
        case .remote: return "remote"
        case .concealed: return "concealed"
        }
    }
    var title: String {
        switch self {
        case .kind(let kind): return kind.label
        case .remote: return L10n.text("С устройств")
        case .concealed: return L10n.text("Скрытые")
        }
    }
    var symbol: String {
        switch self {
        case .kind(let kind): return kind.symbol
        case .remote: return "iphone"
        case .concealed: return "lock"
        }
    }
    var kind: ClipKind? {
        if case .kind(let kind) = self { return kind }
        return nil
    }
}

final class HistoryFilters: NSView, NSPopoverDelegate {
    let sidebar: NSView = NSVisualEffectView()
    private let toolbarButton = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: L10n.text("Фильтры"))!, target: nil, action: nil)
    private let sidebarDateButton = SidebarFilterRow(title: L10n.text("Всё время"), image: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil), value: nil)
    private let sourceRowsContainer = SidebarSourceList()
    private var kindRows: [SidebarFilterRow] = []
    private var sourceRows: [SidebarFilterRow] = []
    private var interactionEnabled = true
    private let datePopover = NSPopover()
    private weak var dateAnchor: NSView?
    private var trackingMenu: NSMenu?
    private var pendingDatePresentation = false
    private var contentType: HistoryContentType?
    private var source: String?
    private var date: HistoryDateFilter = .all
    private var sources: [String] = []
    var onChange: (() -> Void)?
    var onPopoverClosed: (() -> Void)?
    var isPresenting: Bool { datePopover.isShown || trackingMenu != nil || pendingDatePresentation }
    var hasActiveFilters: Bool { contentType != nil || source != nil || date.isActive }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolbarButton.translatesAutoresizingMaskIntoConstraints = false
        toolbarButton.isBordered = false
        toolbarButton.image?.size = NSSize(width: 16, height: 16)
        toolbarButton.target = self; toolbarButton.action = #selector(showFilterMenu)
        addSubview(toolbarButton)
        NSLayoutConstraint.activate([
            toolbarButton.leadingAnchor.constraint(equalTo: leadingAnchor), toolbarButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarButton.topAnchor.constraint(equalTo: topAnchor), toolbarButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 26), heightAnchor.constraint(equalToConstant: 26)
        ])
        sidebarDateButton.target = self; sidebarDateButton.action = #selector(showSidebarDates)
        datePopover.behavior = .transient; datePopover.animates = false; datePopover.delegate = self
        buildSidebar()
        updateTitles()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() { contentType = nil; source = nil; date = .all; dismiss(); updateTitles() }
    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        toolbarButton.isEnabled = enabled; sidebarDateButton.isEnabled = enabled
        for button in kindRows + sourceRows { button.isEnabled = enabled }
    }
    func setSources(_ values: [String]) {
        let ownNames = Set([
            LegacyMigration.previousAppName, BrandIdentity.name, NSRunningApplication.current.localizedName,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ].compactMap { $0 }.map { $0.lowercased() })
        let systemNames: Set<String> = ["loginwindow", "windowserver"]
        let visibleSources = values.filter { !$0.isEmpty && !ownNames.contains($0.lowercased()) && !systemNames.contains($0.lowercased()) }
        if sources != visibleSources { sources = visibleSources; rebuildSourceRows() }
        updateTitles()
    }
    func setSidebarVisible(_ visible: Bool) {
        if !visible, dateAnchor === sidebarDateButton { datePopover.close() }
    }
    func dismiss() { pendingDatePresentation = false; datePopover.close(); trackingMenu?.cancelTracking() }
    func apply(to filter: inout SearchFilter) {
        filter.kind = contentType?.kind; filter.source = source
        filter.remoteOnly = contentType == .remote; filter.concealedOnly = contentType == .concealed
        date.apply(to: &filter)
    }
    func popoverDidClose(_ notification: Notification) { dateAnchor = nil; onPopoverClosed?() }
    @objc private func resetClicked() { reset(); onChange?() }

    private func updateTitles() {
        let summary = [contentType?.title, date.isActive ? date.title : nil, source].compactMap { $0 }.joined(separator: ", ")
        toolbarButton.toolTip = summary.isEmpty ? L10n.text("Фильтры") : L10n.text("Фильтры: \(summary)")
        toolbarButton.setAccessibilityLabel(toolbarButton.toolTip)
        toolbarButton.contentTintColor = hasActiveFilters ? BrandIdentity.accentColor : .secondaryLabelColor
        sidebarDateButton.title = date.isActive ? date.title : L10n.text("Всё время")
        sidebarDateButton.toolTip = L10n.text("Период: \(sidebarDateButton.title)")
        sidebarDateButton.selected = date.isActive
        for row in kindRows { row.selected = row.value == contentType?.value }
        for row in sourceRows { row.selected = row.value == source }
    }

    private func buildSidebar() {
        if let effect = sidebar as? NSVisualEffectView {
            effect.material = .sidebar; effect.blendingMode = .withinWindow; effect.state = .active
            effect.wantsLayer = true; effect.layer?.cornerRadius = 8; effect.layer?.masksToBounds = true
        }
        let typeHeading = heading(L10n.text("Тип содержимого"))
        let types = NSStackView(); types.orientation = .vertical; types.alignment = .leading; types.spacing = 1
        let allTypes = sidebarRow(L10n.text("Все типы"), symbol: "square.grid.2x2", value: nil, action: #selector(sidebarKindClicked))
        kindRows = [allTypes] + HistoryContentType.choices.map {
            sidebarRow($0.title, symbol: $0.symbol, value: $0.value, action: #selector(sidebarKindClicked))
        }
        for row in kindRows {
            types.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: types.widthAnchor).isActive = true
        }
        let dateHeading = heading(L10n.text("Период"))
        let appHeading = heading(L10n.text("Приложения"))
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let document = SidebarDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(scroll)
        sourceRowsContainer.orientation = .vertical; sourceRowsContainer.alignment = .leading; sourceRowsContainer.spacing = 1
        sourceRowsContainer.translatesAutoresizingMaskIntoConstraints = false
        for view in [typeHeading, types, dateHeading, sidebarDateButton, appHeading, sourceRowsContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            typeHeading.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 10),
            typeHeading.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            typeHeading.topAnchor.constraint(equalTo: document.topAnchor, constant: 10),
            types.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            types.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            types.topAnchor.constraint(equalTo: typeHeading.bottomAnchor, constant: 5),
            dateHeading.leadingAnchor.constraint(equalTo: typeHeading.leadingAnchor),
            dateHeading.trailingAnchor.constraint(equalTo: typeHeading.trailingAnchor),
            dateHeading.topAnchor.constraint(equalTo: types.bottomAnchor, constant: 12),
            sidebarDateButton.leadingAnchor.constraint(equalTo: types.leadingAnchor),
            sidebarDateButton.trailingAnchor.constraint(equalTo: types.trailingAnchor),
            sidebarDateButton.topAnchor.constraint(equalTo: dateHeading.bottomAnchor, constant: 5),
            appHeading.leadingAnchor.constraint(equalTo: typeHeading.leadingAnchor),
            appHeading.trailingAnchor.constraint(equalTo: typeHeading.trailingAnchor),
            appHeading.topAnchor.constraint(equalTo: sidebarDateButton.bottomAnchor, constant: 12),
            sourceRowsContainer.leadingAnchor.constraint(equalTo: types.leadingAnchor),
            sourceRowsContainer.trailingAnchor.constraint(equalTo: types.trailingAnchor),
            sourceRowsContainer.topAnchor.constraint(equalTo: appHeading.bottomAnchor, constant: 5),
            sourceRowsContainer.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])
        rebuildSourceRows()
    }

    private func heading(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 11, weight: .semibold); field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func sidebarRow(_ title: String, symbol: String, value: String?, action: Selector) -> SidebarFilterRow {
        let row = SidebarFilterRow(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil), value: value)
        row.target = self; row.action = action; row.isEnabled = interactionEnabled
        return row
    }

    private func rebuildSourceRows() {
        for view in sourceRowsContainer.arrangedSubviews {
            sourceRowsContainer.removeArrangedSubview(view); view.removeFromSuperview()
        }
        sourceRows = [sidebarRow(L10n.text("Все приложения"), symbol: "app", value: nil, action: #selector(sidebarSourceClicked))]
        sourceRows += sources.map { name in
            let row = sidebarRow(name, symbol: "app", value: name, action: #selector(sidebarSourceClicked))
            if let image = applicationIcon(named: name) { row.image = image }
            return row
        }
        for row in sourceRows {
            sourceRowsContainer.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sourceRowsContainer.widthAnchor).isActive = true
        }
    }

    private func applicationIcon(named name: String) -> NSImage? {
        guard let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func chooseKind(_ value: String?) {
        guard interactionEnabled else { return }
        contentType = HistoryContentType(value: value); updateTitles(); onChange?()
    }
    private func chooseSource(_ value: String?) {
        guard interactionEnabled else { return }
        source = value; updateTitles(); onChange?()
    }
    @objc private func sidebarKindClicked(_ sender: SidebarFilterRow) { chooseKind(sender.value) }
    @objc private func sidebarSourceClicked(_ sender: SidebarFilterRow) { chooseSource(sender.value) }
    private func item(_ title: String, symbol: String?, selected: Bool, action: Selector, value: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
        item.representedObject = value; item.state = selected ? .on : .off
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
    private func presentMenu(_ menu: NSMenu, from button: NSButton) {
        guard trackingMenu == nil, !pendingDatePresentation, interactionEnabled else { return }
        trackingMenu = menu
        datePopover.close()
        defer {
            trackingMenu = nil
            if pendingDatePresentation {
                // The panel remains in an interaction while AppKit finishes closing
                // the menu, then the same calendar takes over keyboard focus.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pendingDatePresentation else { return }
                    if self.interactionEnabled, self.window?.isVisible == true, NSApp.isActive {
                        self.showDates(from: self.toolbarButton)
                    }
                    self.pendingDatePresentation = false
                    if !self.datePopover.isShown { self.onPopoverClosed?() }
                }
            } else { onPopoverClosed?() }
        }
        // popUp returns only after selection or cancellation ends menu tracking.
        // Keep the history panel's keyboard handlers suspended for that whole loop.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }
    @objc private func showFilterMenu() {
        presentMenu(makeFilterMenu(), from: toolbarButton)
    }
    func makeFilterMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let typeItem = NSMenuItem(title: contentType.map { L10n.text("Тип: \($0.title)") } ?? L10n.text("Тип"), action: nil, keyEquivalent: "")
        typeItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        typeItem.submenu = kindsMenu(); menu.addItem(typeItem)
        menu.addItem(item(date.isActive ? L10n.text("Дата: \(date.title)…") : L10n.text("Дата…"), symbol: "calendar", selected: date.isActive,
                          action: #selector(showMenuDates)))
        let sourceItem = NSMenuItem(title: source.map { L10n.text("Приложения: \($0)") } ?? L10n.text("Приложения"), action: nil, keyEquivalent: "")
        sourceItem.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        sourceItem.submenu = sourcesMenu(); menu.addItem(sourceItem)
        menu.addItem(.separator())
        let reset = item(L10n.text("Сбросить фильтры"), symbol: "arrow.counterclockwise", selected: false, action: #selector(resetClicked))
        reset.isEnabled = hasActiveFilters; menu.addItem(reset)
        return menu
    }
    private func kindsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(L10n.text("Все типы"), symbol: "square.grid.2x2", selected: contentType == nil, action: #selector(selectKind)))
        menu.addItem(.separator())
        for type in HistoryContentType.choices {
            menu.addItem(item(type.title, symbol: type.symbol, selected: contentType == type, action: #selector(selectKind), value: type.value))
        }
        return menu
    }
    @objc private func selectKind(_ sender: NSMenuItem) {
        chooseKind(sender.representedObject as? String)
    }
    private func sourcesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(L10n.text("Все приложения"), symbol: "app", selected: source == nil, action: #selector(selectSource)))
        menu.addItem(.separator())
        for name in sources {
            let entry = item(name, symbol: "app", selected: name == source, action: #selector(selectSource), value: name)
            if let icon = applicationIcon(named: name) { entry.image = icon }
            menu.addItem(entry)
        }
        if sources.isEmpty { let empty = NSMenuItem(title: L10n.text("Пока нет записей"), action: nil, keyEquivalent: ""); menu.addItem(empty) }
        return menu
    }
    @objc private func selectSource(_ sender: NSMenuItem) { chooseSource(sender.representedObject as? String) }
    @objc private func showMenuDates() { pendingDatePresentation = true }
    @objc private func showSidebarDates() { showDates(from: sidebarDateButton) }
    private func showDates(from anchor: NSView) {
        guard interactionEnabled, anchor.window?.isVisible == true else { return }
        if datePopover.isShown { datePopover.close(); return }
        let controller = HistoryDatePicker(selection: date)
        controller.onSelect = { [weak self] value in
            guard let self else { return }
            self.date = value; self.updateTitles(); self.datePopover.close()
            self.window?.makeKey(); self.onChange?()
        }
        datePopover.contentViewController = controller
        datePopover.contentSize = controller.view.fittingSize
        dateAnchor = anchor
        datePopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

private final class HistoryDatePicker: NSViewController {
    private let start = NSDatePicker()
    private let end = NSDatePicker()
    var onSelect: ((HistoryDateFilter) -> Void)?

    init(selection: HistoryDateFilter) {
        super.init(nibName: nil, bundle: nil)
        start.dateValue = Date(); end.dateValue = Date()
        if case .range(let first, let last) = selection { start.dateValue = first; end.dateValue = last }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let heading = NSTextField(labelWithString: L10n.text("Когда скопировано")); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(heading)
        let presets = NSStackView(); presets.spacing = 6
        for (index, title) in [L10n.text("Всё время"), L10n.text("Сегодня"), L10n.text("Вчера"), L10n.text("7 дней"), L10n.text("30 дней")].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(preset)); button.tag = index
            button.bezelStyle = .recessed; button.font = .systemFont(ofSize: 12); presets.addArrangedSubview(button)
        }
        root.addArrangedSubview(presets)
        let calendars = NSStackView(); calendars.spacing = 16; calendars.alignment = .top
        for (label, picker) in [(L10n.text("С"), start), (L10n.text("По"), end)] {
            picker.datePickerStyle = .clockAndCalendar; picker.datePickerElements = .yearMonthDay
            picker.datePickerMode = .single; picker.locale = L10n.locale
            picker.calendar = .current; picker.timeZone = .current
            picker.drawsBackground = false
            picker.setAccessibilityLabel(label == L10n.text("С") ? L10n.text("Начало периода") : L10n.text("Конец периода"))
            let column = NSStackView(views: [NSTextField(labelWithString: label), picker]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
            calendars.addArrangedSubview(column)
        }
        root.addArrangedSubview(calendars)
        let apply = NSButton(title: L10n.text("Применить период"), target: self, action: #selector(applyRange))
        apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
        root.addArrangedSubview(apply)
        view = root
    }
    @objc private func preset(_ sender: NSButton) {
        let values: [HistoryDateFilter] = [.all, .today, .yesterday, .week, .month]
        onSelect?(values[sender.tag])
    }
    @objc private func applyRange() { onSelect?(.range(min(start.dateValue, end.dateValue), max(start.dateValue, end.dateValue))) }
}
