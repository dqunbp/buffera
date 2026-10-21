import AppKit
import BufferaCore
import BufferaLocalization
import BufferaModels

final class SetupWindow: NSWindowController, NSWindowDelegate {
    var onFinish: ((SetupPreferences, SetupPreferences) throws -> Void)?
    var onSkip: (() -> Void)?
    var onCopyConfiguration: ((String) throws -> Void)?
    private(set) var draft: SetupPreferences
    let initial: SetupPreferences
    let modelsAvailable: Bool
    let modelError: String?
    let access: MCPAccess
    let shortcuts: ShortcutPreferences
    let bundleURL: URL
    private(set) var step = 0
    private let page = NSView()
    private let titleLabel = SetupUI.text("", size: 24, bold: true)
    private let progress = SetupUI.text("", size: 12)
    private let errorLabel = SetupUI.text("", size: 12)
    private let back = NSButton()
    private let next = NSButton()
    private let skip = NSButton()
    private weak var storageValue: NSTextField?
    private var capturePage: (() -> Void)?
    private let titles = [L10n.text("Язык и тема"), L10n.text("Окно истории"), L10n.text("Клавиши"),
                          L10n.text("Хранение"), "MCP", L10n.text("Поиск и ответы")]

    init(initial: SetupPreferences, modelsAvailable: Bool, modelError: String? = nil,
         access: MCPAccess, bundleURL: URL = Bundle.main.bundleURL, shortcuts: ShortcutPreferences = .load()) {
        self.shortcuts = shortcuts
        self.initial = initial; draft = initial; self.modelsAvailable = modelsAvailable
        self.modelError = modelError; self.access = access; self.bundleURL = bundleURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("Настройка Buffera")
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        super.init(window: window)
        window.delegate = self
        build(); render(); window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { skipAll(); return false }

    private func build() {
        guard let root = window?.contentView else { return }
        let skipAll = NSButton(title: L10n.text("Настроить позже"), target: self, action: #selector(skipAll))
        skipAll.bezelStyle = .rounded; skipAll.identifier = .init("setup.skipAll")
        progress.textColor = .secondaryLabelColor
        let top = NSStackView(views: [SetupUI.text("Buffera", size: 17, bold: true), NSView(), skipAll])
        back.title = L10n.text("Назад"); back.target = self; back.action = #selector(goBack)
        next.target = self; next.action = #selector(goNext); next.keyEquivalent = "\r"
        skip.title = L10n.text("Пропустить шаг"); skip.target = self; skip.action = #selector(skipStep)
        for (button, id) in [(back, "back"), (next, "next"), (skip, "skip")] {
            button.bezelStyle = .rounded; button.identifier = .init("setup." + id)
        }
        let footer = NSStackView(views: [back, NSView(), skip, next])
        errorLabel.textColor = .systemRed; errorLabel.isHidden = true
        let stack = SetupUI.column([top, progress, titleLabel, page, errorLabel, footer], spacing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        page.setContentHuggingPriority(.defaultLow, for: .vertical)
        page.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
    }

    private func render() {
        applyDraftTheme()
        titleLabel.stringValue = titles[step]
        progress.stringValue = L10n.text("Шаг \(step + 1) из \(titles.count)")
        back.isEnabled = step > 0
        next.title = step == titles.count - 1 ? L10n.text("Применить и начать") : L10n.text("Далее")
        errorLabel.isHidden = true
        page.subviews.forEach { $0.removeFromSuperview() }
        capturePage = nil
        let content: NSView
        switch step {
        case 0: content = languagePage()
        case 1: content = appearancePage()
        case 2: content = shortcutsPage()
        case 3: content = storagePage()
        case 4: content = mcpPage()
        default: content = modelsPage()
        }
        let scroll = SetupUI.scroll(content)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: page.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor)
        ])
    }

    @objc private func goBack() {
        capturePage?(); step = max(0, step - 1); render()
    }
    @objc private func goNext() {
        capturePage?()
        if step < titles.count - 1 { step += 1; render() }
        else { finish() }
    }
    @objc private func skipStep() {
        draft.skip(step, restoring: initial)
        if step < titles.count - 1 { step += 1; render() }
        else { finish() }
    }
    @objc private func skipAll() { close(); onSkip?() }
    private func finish() {
        do {
            try onFinish?(draft, initial)
            close()
        } catch {
            errorLabel.stringValue = L10n.text("Не удалось сохранить настройки: \(error.localizedDescription)")
            errorLabel.isHidden = false
        }
    }

    private func popup(_ values: [String], selected: Int, id: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: values); popup.selectItem(at: selected)
        popup.identifier = .init("setup." + id)
        return popup
    }
    private func field(_ title: String, _ control: NSView) -> NSView {
        SetupUI.column([SetupUI.text(title, bold: true), control], spacing: 6)
    }
    private func toggle(_ title: String, value: Bool, id: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = value ? .on : .off; button.identifier = .init("setup." + id)
        return button
    }

    @objc private func previewTheme(_ sender: NSPopUpButton) {
        draft.theme = InterfaceTheme.allCases[sender.indexOfSelectedItem]
        applyDraftTheme()
    }
    private func applyDraftTheme() {
        switch draft.theme {
        case .system: window?.appearance = nil
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func languagePage() -> NSView {
        let language = popup(LanguagePreference.allCases.map(\.title),
                             selected: LanguagePreference.allCases.firstIndex(of: draft.language)!, id: "language")
        let theme = popup(InterfaceTheme.allCases.map(\.title),
                         selected: InterfaceTheme.allCases.firstIndex(of: draft.theme)!, id: "theme")
        theme.target = self; theme.action = #selector(previewTheme(_:))
        capturePage = { [weak self] in
            self?.draft.language = LanguagePreference.allCases[language.indexOfSelectedItem]
            self?.draft.theme = InterfaceTheme.allCases[theme.indexOfSelectedItem]
        }
        return SetupUI.column([
            SetupUI.text(L10n.text("Настройте Buffera под себя. Каждый шаг можно пропустить; всё это доступно и в настройках.")),
            field(L10n.text("Язык интерфейса"), language), field(L10n.text("Тема"), theme),
            SetupUI.text(L10n.text("Изменения применятся в конце. Для смены языка понадобится перезапуск."), size: 12)
        ])
    }

    private func appearancePage() -> NSView {
        let mode = popup(HistoryAppearance.Mode.allCases.map(\.title),
                         selected: HistoryAppearance.Mode.allCases.firstIndex(of: draft.appearance.mode)!, id: "mode")
        let columns = popup((1...4).map(String.init), selected: draft.appearance.columns - 1, id: "columns")
        let rows = popup((3...12).map(String.init), selected: draft.appearance.visibleRows - 3, id: "rows")
        let sidebar = toggle(L10n.text("Показывать боковую панель с фильтрами"), value: draft.appearance.sidebarVisible, id: "sidebar")
        capturePage = { [weak self] in
            self?.draft.appearance = HistoryAppearance(mode: HistoryAppearance.Mode.allCases[mode.indexOfSelectedItem],
                columns: columns.indexOfSelectedItem + 1, visibleRows: rows.indexOfSelectedItem + 3, sidebarVisible: sidebar.state == .on)
        }
        return SetupUI.column([field(L10n.text("Расположение окна"), mode), field(L10n.text("Колонки"), columns),
                               field(L10n.text("Видимых строк"), rows), sidebar])
    }

    private func shortcutsPage() -> NSView {
        let quick = SetupUI.card([
            SetupUI.text(L10n.text("Быстро выбрать запись"), bold: true),
            SetupUI.text(L10n.text("\(shortcuts.nextTitle) — следующая     \(shortcuts.previousTitle) — предыдущая"), size: 16, bold: true),
            SetupUI.text(L10n.text("Нажмите \(shortcuts.nextTitle) несколько раз, не отпуская \(shortcuts.base.title). Для движения назад — \(shortcuts.previousTitle). Когда выбрали запись, отпустите \(shortcuts.base.title) — она скопируется."), size: 12)
        ], tinted: true)
        return SetupUI.column([
            SetupUI.card([SetupUI.text(L10n.text("Открыть историю"), bold: true), SetupUI.text(shortcuts.nextTitle, size: 30, bold: true), quick]),
            SetupUI.card([SetupUI.text(L10n.text("Выбрать и скопировать"), bold: true), SetupUI.text("↑ ↓  →  Enter", size: 27, bold: true)]),
            SetupUI.card([SetupUI.text(L10n.text("Посмотреть подробно"), bold: true), SetupUI.text(L10n.text("Пробел"), size: 27, bold: true)])
        ], spacing: 12)
    }

    private func storagePage() -> NSView {
        let values = Array(Set(HistoryLimits.countChoices + [draft.limits.maxCount])).sorted()
        let count = popup(values.map { $0.formatted(.number.locale(L10n.locale)) },
                          selected: values.firstIndex(of: draft.limits.maxCount)!, id: "count")
        let bytes = NSSlider(value: Double(draft.limits.maxBytes) / 1_000_000_000,
                             minValue: 1, maxValue: 20, target: nil, action: nil)
        bytes.numberOfTickMarks = 20; bytes.allowsTickMarkValuesOnly = true
        bytes.identifier = .init("setup.bytes")
        let value = SetupUI.text("", size: 16, bold: true)
        storageValue = value
        bytes.target = self; bytes.action = #selector(storageChanged(_:))
        value.stringValue = L10n.text("\((Double(draft.limits.maxBytes) / Double(HistoryLimits.bytesPerGigabyte)).formatted(.number.locale(L10n.locale))) ГБ")
        bytes.setAccessibilityValueDescription(value.stringValue)
        capturePage = { [weak self] in
            self?.draft.limits.maxCount = values[count.indexOfSelectedItem]
        }
        return SetupUI.column([field(L10n.text("Количество записей"), count),
            field(L10n.text("Размер истории: от 1 до 20 ГБ"), bytes), value,
            SetupUI.text(L10n.text("При следующем копировании самые старые записи сверх лимита удалятся. Избранное сохраняется."))])
    }

    @objc private func storageChanged(_ sender: NSSlider) {
        draft.limits.maxBytes = Int(sender.doubleValue * Double(HistoryLimits.bytesPerGigabyte))
        storageValue?.stringValue = L10n.text("\(sender.doubleValue.formatted(.number.locale(L10n.locale))) ГБ")
        sender.setAccessibilityValueDescription(storageValue?.stringValue)
    }

    private func mcpPage() -> NSView {
        let mcp = MCPSettingsView(access: access, bundleURL: bundleURL)
        mcp.readEnabled = { [weak self] in self?.draft.mcpEnabled ?? false }
        mcp.writeEnabled = { [weak self] in self?.draft.mcpEnabled = $0 }
        mcp.onCopyConfiguration = { [weak self] value in
            guard let copy = self?.onCopyConfiguration else { throw MCPSettingsError.copyUnavailable }
            try copy(value)
        }
        mcp.refresh()
        return SetupUI.column([SetupUI.text(L10n.text("Подключите историю к своему AI-агенту. Разрешение изменится после завершения настройки; копирование команды само по себе доступ не включает.")), mcp])
    }

    private func modelsPage() -> NSView {
        let search = toggle(L10n.text("Включить поиск по смыслу"), value: draft.embeddingEnabled, id: "embedding")
        let assistant = toggle(L10n.text("Включить локального помощника"), value: draft.assistantEnabled, id: "assistant")
        let power = toggle(L10n.text("Готовить поиск только от внешнего питания"), value: draft.onlyOnExternalPower, id: "power")
        search.isEnabled = modelsAvailable; assistant.isEnabled = modelsAvailable
        capturePage = { [weak self] in
            self?.draft.embeddingEnabled = search.state == .on
            self?.draft.assistantEnabled = assistant.state == .on
            self?.draft.onlyOnExternalPower = power.state == .on
        }
        let cards = LocalModelCatalog.models.map { descriptor -> NSView in
            let size = ByteCountFormatter.string(fromByteCount: descriptor.byteCount, countStyle: .file)
            let purpose = descriptor.role == .embedding
                ? L10n.text("Находит записи по смыслу, даже если вы не помните точные слова.")
                : L10n.text("Отвечает на вопросы по истории. Для поиска источников включите также поиск по смыслу.")
            return SetupUI.card([descriptor.role == .embedding ? search : assistant,
                SetupUI.text(purpose), SetupUI.text("\(descriptor.title) · \(size)", size: 12)])
        }
        var views: [NSView] = cards + [power, SetupUI.text(L10n.text("Недостающие модели скачаются после «Применить и начать». Затем всё работает локально. Подготовка поиска может занять время и расходует заряд."), size: 12)]
        if !modelsAvailable {
            views.append(SetupUI.text(modelError ?? L10n.text("Локальные модели доступны на Mac с Apple Silicon."), size: 12))
        }
        return SetupUI.column(views)
    }
}
