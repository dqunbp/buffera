import AppKit
import BuferaCore

enum HistoryDateFilter {
    case all, today, yesterday, week, month, range(Date, Date)

    var title: String {
        switch self {
        case .all: return "Дата"
        case .today: return "Сегодня"
        case .yesterday: return "Вчера"
        case .week: return "7 дней"
        case .month: return "30 дней"
        case .range(let start, let end):
            let format = DateFormatter(); format.locale = Locale(identifier: "ru_RU"); format.dateFormat = "d MMM"
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

private final class FilterChip: NSButton {
    var active = false { didSet { updateColors() } }
    override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width + 16, height: 28) }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = title; image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading; imageScaling = .scaleProportionallyDown
        bezelStyle = .roundRect; isBordered = false; font = .systemFont(ofSize: 12, weight: .medium)
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true; layer?.cornerRadius = 8
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (active ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.labelColor.withAlphaComponent(0.07)).cgColor
        }
        contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
    }
}

final class HistoryFilters: NSView, NSPopoverDelegate {
    private let kindButton = FilterChip(title: "Тип", symbol: "square.grid.2x2")
    private let dateButton = FilterChip(title: "Дата", symbol: "calendar")
    private let sourceButton = FilterChip(title: "Приложение", symbol: "app")
    private let resetButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Сбросить фильтры")!, target: nil, action: nil)
    private let datePopover = NSPopover()
    private var trackingMenu: NSMenu?
    private var kind: ClipKind?
    private var source: String?
    private var date: HistoryDateFilter = .all
    private var sources: [String] = []
    var onChange: (() -> Void)?
    var onPopoverClosed: (() -> Void)?
    var isPresenting: Bool { datePopover.isShown || trackingMenu != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let row = NSStackView(views: [kindButton, dateButton, sourceButton, resetButton]); row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28), kindButton.widthAnchor.constraint(equalToConstant: 106),
            dateButton.widthAnchor.constraint(equalToConstant: 136), sourceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            resetButton.widthAnchor.constraint(equalToConstant: 24)
        ])
        kindButton.target = self; kindButton.action = #selector(showKinds)
        sourceButton.target = self; sourceButton.action = #selector(showSources)
        dateButton.target = self; dateButton.action = #selector(showDates)
        resetButton.target = self; resetButton.action = #selector(resetClicked)
        resetButton.isBordered = false; resetButton.contentTintColor = .secondaryLabelColor
        resetButton.toolTip = "Сбросить тип, дату и приложение"
        datePopover.behavior = .transient; datePopover.animates = false; datePopover.delegate = self
        updateTitles()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() { kind = nil; source = nil; date = .all; dismiss(); updateTitles() }
    func setInteractionEnabled(_ enabled: Bool) {
        for button in [kindButton, dateButton, sourceButton] { button.isEnabled = enabled }
        resetButton.isEnabled = enabled && (kind != nil || source != nil || date.isActive)
    }
    func setSources(_ values: [String]) { sources = values }
    func dismiss() { datePopover.close(); trackingMenu?.cancelTracking() }
    func apply(to filter: inout SearchFilter) { filter.kind = kind; filter.source = source; date.apply(to: &filter) }
    func popoverDidClose(_ notification: Notification) { onPopoverClosed?() }
    @objc private func resetClicked() { reset(); onChange?() }

    private func updateTitles() {
        kindButton.title = kind?.label ?? "Тип"; kindButton.active = kind != nil
        dateButton.title = date.title; dateButton.active = date.isActive
        sourceButton.title = source ?? "Приложение"; sourceButton.active = source != nil
        kindButton.toolTip = "Тип содержимого: \(kind?.label ?? "все")"
        dateButton.toolTip = "Дата копирования: \(date.isActive ? date.title : "за всё время")"
        sourceButton.toolTip = "Приложение: \(source ?? "все")"
        resetButton.isEnabled = kind != nil || source != nil || date.isActive
    }

    private func item(_ title: String, symbol: String?, selected: Bool, action: Selector, value: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
        item.representedObject = value; item.state = selected ? .on : .off
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
    private func presentMenu(_ menu: NSMenu, from button: NSButton) {
        guard trackingMenu == nil else { return }
        trackingMenu = menu
        datePopover.close()
        defer {
            trackingMenu = nil
            onPopoverClosed?()
        }
        // popUp returns only after selection or cancellation ends menu tracking.
        // Keep the history panel's keyboard handlers suspended for that whole loop.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }
    @objc private func showKinds() {
        let menu = NSMenu()
        menu.addItem(item("Все типы", symbol: "square.grid.2x2", selected: kind == nil, action: #selector(selectKind)))
        menu.addItem(.separator())
        for type in ClipKind.allCases {
            menu.addItem(item(type.label, symbol: type.symbol, selected: kind == type, action: #selector(selectKind), value: type.rawValue))
        }
        presentMenu(menu, from: kindButton)
    }
    @objc private func selectKind(_ sender: NSMenuItem) {
        kind = (sender.representedObject as? String).flatMap(ClipKind.init(rawValue:)); updateTitles(); onChange?()
    }
    @objc private func showSources() {
        let menu = NSMenu()
        menu.addItem(item("Все приложения", symbol: "app", selected: source == nil, action: #selector(selectSource)))
        menu.addItem(.separator())
        for name in sources {
            let entry = item(name, symbol: "app", selected: name == source, action: #selector(selectSource), value: name)
            if let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16); entry.image = icon
            }
            menu.addItem(entry)
        }
        if sources.isEmpty { let empty = NSMenuItem(title: "Пока нет записей", action: nil, keyEquivalent: ""); menu.addItem(empty) }
        presentMenu(menu, from: sourceButton)
    }
    @objc private func selectSource(_ sender: NSMenuItem) { source = sender.representedObject as? String; updateTitles(); onChange?() }
    @objc private func showDates() {
        if datePopover.isShown { datePopover.close(); return }
        let controller = HistoryDatePicker(selection: date)
        controller.onSelect = { [weak self] value in
            guard let self else { return }
            self.date = value; self.updateTitles(); self.datePopover.close()
            self.window?.makeKey(); self.onChange?()
        }
        datePopover.contentViewController = controller
        datePopover.contentSize = controller.view.fittingSize
        datePopover.show(relativeTo: dateButton.bounds, of: dateButton, preferredEdge: .maxY)
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
        let heading = NSTextField(labelWithString: "Когда скопировано"); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(heading)
        let presets = NSStackView(); presets.spacing = 6
        for (index, title) in ["Всё время", "Сегодня", "Вчера", "7 дней", "30 дней"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(preset)); button.tag = index
            button.bezelStyle = .recessed; button.font = .systemFont(ofSize: 12); presets.addArrangedSubview(button)
        }
        root.addArrangedSubview(presets)
        let calendars = NSStackView(); calendars.spacing = 16; calendars.alignment = .top
        for (label, picker) in [("С", start), ("По", end)] {
            picker.datePickerStyle = .clockAndCalendar; picker.datePickerElements = .yearMonthDay
            picker.datePickerMode = .single; picker.locale = Locale(identifier: "ru_RU")
            picker.calendar = .current; picker.timeZone = .current
            picker.drawsBackground = false
            picker.setAccessibilityLabel(label == "С" ? "Начало периода" : "Конец периода")
            let column = NSStackView(views: [NSTextField(labelWithString: label), picker]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
            calendars.addArrangedSubview(column)
        }
        root.addArrangedSubview(calendars)
        let apply = NSButton(title: "Применить период", target: self, action: #selector(applyRange))
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
