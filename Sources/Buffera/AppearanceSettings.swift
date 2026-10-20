import AppKit
import BufferaCore
import BufferaModels

/// A retained settings window, independent of the history panel's focus/lifetime.
final class SettingsWindow: NSWindowController {
    var onAppearanceChange: ((HistoryAppearance) -> Void)?
    var onLimitsChange: ((HistoryLimits) -> Void)?
    var onRevealData: (() -> Void)?
    var onCopyMCPConfiguration: ((String) throws -> Void)?
    var onCheckModel: ((ModelRole) -> Void)?
    var onCancelModelCheck: ((ModelRole) -> Void)?
    var onWillDisableOrRemoveModel: ((ModelRole) -> Void)?

    private let settings: SettingsContentController

    init(modelManager: LocalModelManager? = nil, modelError: String? = nil,
         mcpAccess: MCPAccess = MCPAccess(), bundleURL: URL = Bundle.main.bundleURL) {
        settings = SettingsContentController(modelManager: modelManager, modelError: modelError,
                                             mcpAccess: mcpAccess, bundleURL: bundleURL)
        let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 510),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Настройки \(BrandIdentity.name)"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("BufferaSettingsWindow")
        if !window.setFrameUsingName("BufferaSettingsWindow") {
            window.center()
        } else if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        super.init(window: window)
        window.contentViewController = settings
        settings.onAppearanceChange = { [weak self] value in self?.onAppearanceChange?(value) }
        settings.onLimitsChange = { [weak self] value in self?.onLimitsChange?(value) }
        settings.onRevealData = { [weak self] in self?.onRevealData?() }
        settings.onCopyMCPConfiguration = { [weak self] configuration in
            guard let copy = self?.onCopyMCPConfiguration else { throw MCPSettingsError.copyUnavailable }
            try copy(configuration)
        }
        settings.onCheckModel = { [weak self] role in self?.onCheckModel?(role) }
        settings.onCancelModelCheck = { [weak self] role in self?.onCancelModelCheck?(role) }
        settings.onWillDisableOrRemoveModel = { [weak self] role in self?.onWillDisableOrRemoveModel?(role) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        settings.updateAppearance(HistoryAppearance.load())
        settings.updateLimits(HistoryLimits.load())
        settings.refreshMCPAccess()
        settings.refreshModels()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateAppearance(_ value: HistoryAppearance) { settings.updateAppearance(value) }
    func updateModels(_ snapshots: [LocalModelSnapshot]) { settings.updateModels(snapshots) }
    func updateModelCheck(role: ModelRole, status: String, running: Bool) {
        settings.updateModelCheck(role: role, status: status, running: running)
    }
}

private final class SettingsPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 13 && modifiers == .command {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SettingsContentController: NSViewController {
    var onAppearanceChange: ((HistoryAppearance) -> Void)?
    var onLimitsChange: ((HistoryLimits) -> Void)?
    var onRevealData: (() -> Void)?
    var onCopyMCPConfiguration: ((String) throws -> Void)?
    var onCheckModel: ((ModelRole) -> Void)?
    var onCancelModelCheck: ((ModelRole) -> Void)?
    var onWillDisableOrRemoveModel: ((ModelRole) -> Void)?

    private let mcp: MCPSettingsView
    private let models: ModelSettingsView
    private var appearance = HistoryAppearance.load()
    private var limits = HistoryLimits.load()
    private let mode = NSPopUpButton()
    private let columns = NSPopUpButton()
    private let rows = NSPopUpButton()
    private let sidebar = NSButton(checkboxWithTitle: "Показывать боковую панель с фильтрами", target: nil, action: nil)
    private let count = NSPopUpButton()
    private let bytes = NSPopUpButton()
    private var countValues = HistoryLimits.countChoices
    private var byteValues = HistoryLimits.byteChoices
    private let tabs = NSSegmentedControl(labels: ["Вид", "История", "Клавиши", "Агенты", "Модели"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let body = NSView()
    private var pages: [NSView] = []

    init(modelManager: LocalModelManager?, modelError: String?, mcpAccess: MCPAccess, bundleURL: URL) {
        mcp = MCPSettingsView(access: mcpAccess, bundleURL: bundleURL)
        models = ModelSettingsView(manager: modelManager, unavailableMessage: modelError)
        super.init(nibName: nil, bundle: nil)
        mcp.onCopyConfiguration = { [weak self] configuration in
            guard let copy = self?.onCopyMCPConfiguration else { throw MCPSettingsError.copyUnavailable }
            try copy(configuration)
        }
        models.onCheck = { [weak self] role in self?.onCheckModel?(role) }
        models.onCancelCheck = { [weak self] role in self?.onCancelModelCheck?(role) }
        models.onWillDisableOrRemove = { [weak self] role in self?.onWillDisableOrRemoveModel?(role) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshMCPAccess() { mcp.refresh() }
    func refreshModels() { models.refresh() }
    func updateModels(_ snapshots: [LocalModelSnapshot]) { models.update(snapshots) }
    func updateModelCheck(role: ModelRole, status: String, running: Bool) {
        models.updateCheck(role: role, status: status, running: running)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 510))
        let icon = NSImageView(image: BrandIdentity.appIcon(size: 64))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(BrandIdentity.name)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let name = label(BrandIdentity.name, size: 25, weight: .bold)
        let tagline = label("Держит всё, что ты копируешь.", size: 12, color: .secondaryLabelColor)
        let identity = vertical([name, tagline], spacing: 3)
        let header = NSStackView(views: [icon, identity])
        header.orientation = .horizontal; header.spacing = 14; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded
        tabs.controlSize = .regular
        tabs.target = self; tabs.action = #selector(changeTab)
        tabs.setAccessibilityLabel("Раздел настроек")
        for index in 0..<tabs.segmentCount { tabs.setWidth(100, forSegment: index) }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        let footer = label("Изменения сохраняются сразу", size: 11, color: .tertiaryLabelColor)
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 21),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            body.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 22),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        pages = [appearancePage(), historyPage(), keyboardPage(), mcp, models]
        view = root
        updateAppearance(appearance)
        updateLimits(limits)
        presentPage(0)
    }

    func updateAppearance(_ value: HistoryAppearance) {
        appearance = value
        guard isViewLoaded else { return }
        mode.selectItem(at: HistoryAppearance.Mode.allCases.firstIndex(of: value.mode) ?? 0)
        columns.selectItem(at: value.columns - 1)
        rows.selectItem(at: value.visibleRows - 3)
        sidebar.state = value.sidebarVisible ? .on : .off
    }

    func updateLimits(_ value: HistoryLimits) {
        limits = value
        guard isViewLoaded else { return }
        // Preserve valid custom values from earlier versions rather than changing them on an unrelated edit.
        countValues = Array(Set(HistoryLimits.countChoices + [value.maxCount])).sorted()
        byteValues = Array(Set(HistoryLimits.byteChoices + [value.maxBytes])).sorted()
        count.removeAllItems(); count.addItems(withTitles: countValues.map { $0.formatted(.number.locale(Locale(identifier: "ru_RU"))) })
        bytes.removeAllItems(); bytes.addItems(withTitles: byteValues.map {
            "\((Double($0) / 1_000_000_000).formatted(.number.locale(Locale(identifier: "ru_RU")))) ГБ"
        })
        count.selectItem(at: countValues.firstIndex(of: value.maxCount) ?? 0)
        bytes.selectItem(at: byteValues.firstIndex(of: value.maxBytes) ?? 0)
    }

    private func appearancePage() -> NSView {
        mode.addItems(withTitles: HistoryAppearance.Mode.allCases.map(\.title))
        columns.addItems(withTitles: ["1 — список", "2 — сетка", "3 — сетка", "4 — сетка"])
        rows.addItems(withTitles: (3...12).map(String.init))
        for (button, title) in [(mode, "Расположение окна"), (columns, "Количество колонок"), (rows, "Видимых строк")] {
            configure(button, label: title, action: #selector(appearanceChanged))
        }
        sidebar.target = self; sidebar.action = #selector(appearanceChanged)
        sidebar.font = .systemFont(ofSize: 12)
        let grid = form([
            [label("Расположение"), mode],
            [label("Карточки"), columns],
            [label("Видимых строк"), rows]
        ])
        let note = paragraph("Одна колонка — список, несколько — сетка. Число строк задаёт высоту карточек. В боковой панели это максимальная высота: короткие записи занимают меньше места.")
        let tip = info(symbol: "sidebar.left", title: "У каждого вида — своё место",
                       text: "Обычное окно можно перемещать и менять в размере. Боковая панель выезжает у выбранного края экрана.")
        let page = vertical([grid, sidebar, note, tip], spacing: 15)
        for child in [grid, note, tip] { child.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        return page
    }

    private func historyPage() -> NSView {
        configure(count, label: "Лимит записей", action: #selector(limitsChanged))
        configure(bytes, label: "Лимит объёма истории", action: #selector(limitsChanged))
        let grid = form([[label("Количество записей"), count], [label("Объём истории"), bytes]])
        let note = paragraph("При следующем копировании старые записи сверх лимита будут удалены. Избранное сохраняется и не входит в эти лимиты.")
        let ocr = info(symbol: "text.viewfinder", title: "Текст на картинках тоже находится",
                       text: "Распознавание работает в фоне на Mac. Русский и английский текст участвуют в обычном поиске; скрытые записи пропускаются.")
        let folder = NSButton(title: "Открыть папку данных", target: self, action: #selector(revealData))
        folder.bezelStyle = .rounded
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folder.imagePosition = .imageLeading
        let storage = paragraph("История хранится локально. Маскировка скрывает содержимое в интерфейсе, но не шифрует базу.")
        let page = vertical([grid, note, ocr, folder, storage], spacing: 14)
        for child in [grid, note, ocr, storage] { child.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        return page
    }

    private func keyboardPage() -> NSView {
        let navigation = [
            ("Открыть / следующая запись", "⌘⌥V"),
            ("Предыдущая запись", "⌘⌥C"),
            ("Выбрать запись", "↑ ↓ ← →"),
            ("Первые девять записей", "⌘1–9"),
            ("Перейти к поиску", "⌘F"),
            ("Вся история", "⌘0"),
            ("Боковая панель", "⌘⌥S"),
            ("Настройки", "⌘,"),
            ("Закрыть просмотр / окно", "Esc")
        ]
        let actions = ClipCardAction.allCases.map { ($0.title, $0.shortcut) }
        let left = shortcutGroup("Навигация", entries: navigation)
        let right = shortcutGroup("Выбранная запись", entries: actions)
        let groups = NSStackView(views: [left, right])
        groups.orientation = .horizontal; groups.alignment = .top; groups.spacing = 24
        groups.distribution = .fillEqually
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        let note = paragraph("Одно ⌘⌥V с отпусканием оставляет окно открытым; дальше V/C только двигают выбор. Для быстрого выбора удерживайте ⌘⌥ с самого открытия, нажмите V/C ещё раз и отпустите. Enter — выбрать, пробел — просмотр (из поиска — ⌘Y). Вставка — ⌘V в нужном приложении.")
        let page = vertical([groups, note], spacing: 18)
        groups.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        return page
    }

    private func shortcutGroup(_ heading: String, entries: [(String, String)]) -> NSView {
        let title = label(heading, size: 10, weight: .semibold, color: .secondaryLabelColor)
        let rows = entries.map { text, keys -> NSView in
            let row = NSView()
            let description = label(text, size: 11)
            let shortcut = label(keys, size: 11, weight: .medium)
            for field in [description, shortcut] {
                field.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(field)
            }
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 16),
                description.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                description.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                shortcut.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                shortcut.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: description.trailingAnchor, constant: 8)
            ])
            return row
        }
        let list = vertical(rows, spacing: 7)
        list.heightAnchor.constraint(equalToConstant: CGFloat(entries.count * 16 + max(0, entries.count - 1) * 7)).isActive = true
        for row in rows { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        let group = vertical([title, list], spacing: 12)
        group.setContentHuggingPriority(.required, for: .vertical)
        list.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func configure(_ popup: NSPopUpButton, label title: String, action: Selector) {
        popup.font = .systemFont(ofSize: 12)
        popup.setAccessibilityLabel(title)
        popup.target = self; popup.action = action
        popup.widthAnchor.constraint(equalToConstant: 232).isActive = true
    }

    private func form(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 20; grid.rowSpacing = 13
        grid.xPlacement = .fill; grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        return grid
    }

    private func info(symbol: String, title: String, text: String) -> NSView {
        let box = NSBox()
        box.boxType = .custom; box.borderWidth = 0
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 12
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemPurple
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let copy = vertical([label(title, size: 12, weight: .semibold), paragraph(text)], spacing: 5)
        let row = NSStackView(views: [icon, copy])
        row.orientation = .horizontal; row.spacing = 12; row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(row)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
                row.topAnchor.constraint(equalTo: content.topAnchor, constant: 13),
                row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -13)
            ])
        }
        return box
    }

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
        return field
    }

    private func paragraph(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    private func vertical(_ children: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: children)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }

    private func presentPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        for view in body.subviews { view.removeFromSuperview() }
        let page = pages[index]
        page.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            page.topAnchor.constraint(equalTo: body.topAnchor),
            page === models
                ? page.bottomAnchor.constraint(equalTo: body.bottomAnchor)
                : page.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor)
        ])
    }

    @objc private func changeTab() { presentPage(tabs.selectedSegment) }

    @objc private func appearanceChanged() {
        let modes = HistoryAppearance.Mode.allCases
        guard modes.indices.contains(mode.indexOfSelectedItem) else { return }
        let next = HistoryAppearance(mode: modes[mode.indexOfSelectedItem], columns: columns.indexOfSelectedItem + 1,
                                     visibleRows: rows.indexOfSelectedItem + 3, sidebarVisible: sidebar.state == .on)
        guard appearance != next else { return }
        appearance = next
        next.save()
        onAppearanceChange?(next)
    }

    @objc private func limitsChanged() {
        guard countValues.indices.contains(count.indexOfSelectedItem), byteValues.indices.contains(bytes.indexOfSelectedItem) else { return }
        let next = HistoryLimits(maxCount: countValues[count.indexOfSelectedItem], maxBytes: byteValues[bytes.indexOfSelectedItem])
        guard limits != next else { return }
        limits = next
        next.save()
        onLimitsChange?(next)
    }

    @objc private func revealData() { onRevealData?() }
}
