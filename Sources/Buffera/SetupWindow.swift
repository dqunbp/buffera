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
    private(set) var step = SetupStep.language
    private let page = NSView()
    private let titleLabel = SetupUI.text("", size: 24, bold: true)
    private let progress = SetupUI.text("", size: 12)
    private let errorLabel = SetupUI.text("", size: 12)
    private let back = NSButton()
    private let next = NSButton()
    private let skip = NSButton()
    private lazy var login = toggle(L10n.text("Запускать Buffera при входе в систему"), value: draft.launchAtLogin, id: "launchAtLogin")
    private lazy var loginCard = SetupUI.card([login])
    private weak var pasteAccessHint: NSTextField?
    private let canPostPaste: () -> Bool
    private weak var storageValue: NSTextField?
    private var capturePage: (() -> Void)?

    init(initial: SetupPreferences, modelsAvailable: Bool, modelError: String? = nil,
         access: MCPAccess, bundleURL: URL = Bundle.main.bundleURL, shortcuts: ShortcutPreferences = .load(),
         canPostPaste: @escaping () -> Bool = CGPreflightPostEventAccess) {
        self.canPostPaste = canPostPaste
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
        progress.identifier = .init("setup.progress")
        titleLabel.identifier = .init("setup.title")
        let top = NSStackView(views: [SetupUI.text("Buffera", size: 17, bold: true), NSView(), skipAll])
        back.title = L10n.text("Назад"); back.target = self; back.action = #selector(goBack)
        next.target = self; next.action = #selector(goNext); next.keyEquivalent = "\r"
        skip.title = L10n.text("Пропустить шаг"); skip.target = self; skip.action = #selector(skipStep)
        for (button, id) in [(back, "back"), (next, "next"), (skip, "skip")] {
            button.bezelStyle = .rounded; button.identifier = .init("setup." + id)
        }
        let footer = NSStackView(views: [back, NSView(), skip, next])
        errorLabel.textColor = .systemRed; errorLabel.isHidden = true
        let loginHeight = loginCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 50)
        loginHeight.priority = .defaultHigh
        loginHeight.isActive = true
        let stack = SetupUI.column([top, progress, titleLabel, loginCard, page, errorLabel, footer], spacing: 18)
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
        titleLabel.stringValue = step.title
        progress.stringValue = L10n.text("Шаг \(step.rawValue + 1) из \(SetupStep.allCases.count)")
        loginCard.isHidden = step != .models
        login.state = draft.launchAtLogin ? .on : .off
        back.isEnabled = step.rawValue > 0
        next.title = step == SetupStep.allCases.last ? L10n.text("Применить и начать") : L10n.text("Далее")
        errorLabel.isHidden = true
        page.subviews.forEach { $0.removeFromSuperview() }
        capturePage = nil
        let content: NSView
        switch step {
        case .language: content = languagePage()
        case .shortcuts: content = shortcutsPage()
        case .storage: content = storagePage()
        case .mcp: content = mcpPage()
        case .models: content = modelsPage()
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
        capturePage?(); step = SetupStep(rawValue: step.rawValue - 1) ?? step; render()
    }
    @objc private func goNext() {
        capturePage?()
        advance()
    }
    @objc private func skipStep() {
        draft.skip(step, restoring: initial)
        advance()
    }
    private func advance() {
        if let following = SetupStep(rawValue: step.rawValue + 1) { step = following; render() }
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

    private func shortcutsPage() -> NSView {
        let action = #selector(selectEnterAction(_:))
        let copy = NSButton(radioButtonWithTitle: L10n.text("Поместить в буфер обмена — затем вставьте через ⌘V"), target: self, action: action)
        let paste = NSButton(radioButtonWithTitle: L10n.text("Сразу вставить в активное приложение"), target: self, action: action)
        copy.identifier = .init("setup.copyOnEnter")
        paste.identifier = .init("setup.pasteOnEnter")
        copy.state = draft.pasteOnEnter ? .off : .on
        paste.state = draft.pasteOnEnter ? .on : .off
        let hint = SetupUI.text(L10n.text("После завершения настройки macOS попросит разрешение, чтобы Buffera могла нажимать ⌘V за вас."), size: 12)
        hint.identifier = .init("setup.pasteAccessHint")
        hint.isHidden = !draft.pasteOnEnter || canPostPaste()
        pasteAccessHint = hint
        func note(_ value: String) -> NSTextField {
            let label = SetupUI.text(value, size: 13)
            label.textColor = .secondaryLabelColor
            return label
        }
        let rows = [
            SetupUI.instruction(1, title: L10n.text("Откройте историю"), keys: [shortcuts.nextTitle], details: [
                note(L10n.text("Сочетание клавиш можно будет изменить в «Настройки → Клавиши»."))
            ]),
            SetupUI.instruction(2, title: L10n.text("Выберите запись"), keys: ["↑", "↓"], details: [
                note(L10n.text("Перемещайтесь стрелками. Нажмите пробел для просмотра записи."))
            ]),
            SetupUI.instruction(3, title: L10n.text("Нажмите Enter"), keys: ["↩ Enter"], details: [
                SetupUI.text(L10n.text("Что делать с выбранной записью?")), copy, paste, hint
            ])
        ]
        let quick = SetupUI.card([
            SetupUI.text(L10n.text("Быстрый выбор с клавиатуры"), bold: true),
            SetupUI.text(L10n.text("\(shortcuts.nextTitle) — следующая     \(shortcuts.previousTitle) — предыдущая"), bold: true),
            note(L10n.text("Нажмите \(shortcuts.nextTitle) несколько раз, не отпуская \(shortcuts.base.title). Для движения назад — \(shortcuts.previousTitle). Когда выбрали запись, отпустите \(shortcuts.base.title) — она скопируется."))
        ], tinted: true)
        return SetupUI.column([SetupUI.column(rows, spacing: 0), quick], spacing: 12)
    }

    @objc private func selectEnterAction(_ sender: NSButton) {
        draft.pasteOnEnter = sender.identifier?.rawValue == "setup.pasteOnEnter"
        pasteAccessHint?.isHidden = !draft.pasteOnEnter || canPostPaste()
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
            self?.draft.launchAtLogin = self?.login.state == .on
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
        var views: [NSView] = [SetupUI.text(L10n.text("Поиск и ответы"), size: 16, bold: true)] + cards + [power, SetupUI.text(L10n.text("Недостающие модели скачаются после «Применить и начать». Затем всё работает локально. Подготовка поиска может занять время и расходует заряд."), size: 12)]
        if !modelsAvailable {
            views.append(SetupUI.text(modelError ?? L10n.text("Локальные модели доступны на Mac с Apple Silicon."), size: 12))
        }
        return SetupUI.column(views)
    }
}
