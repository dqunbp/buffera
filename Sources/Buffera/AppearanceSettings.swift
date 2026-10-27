import BufferaLocalization
import AppKit
import BufferaCore
import BufferaModels

/// A retained settings window, independent of the history panel's focus/lifetime.
final class SettingsWindow: NSWindowController {
    var onShortcutsChange: ((ShortcutPreferences) throws -> Void)?
    var onAppearanceChange: ((HistoryAppearance) -> Void)?
    var onLimitsChange: ((HistoryLimits) -> Void)?
    var onSecretHistoryChange: SecretHistorySettingsView.Apply?
    var onShowSetup: (() -> Void)?
    var onRestart: (() -> Void)?
    var onRevealData: (() -> Void)?
    var onCopyMCPConfiguration: ((String) throws -> Void)?
    var onCheckModel: ((ModelRole) -> Void)?
    var onCancelModelCheck: ((ModelRole) -> Void)?
    var onWillDisableOrRemoveModel: ((ModelRole) -> Void)?
    var onRetryEmbeddingIndex: (() -> Void)?
    var onOnlyPrepareOnExternalPowerChanged: ((Bool) -> Void)?
    var onContinueEmbeddingPreparation: (() -> Void)?

    private let settings: SettingsContentController
    private let limitsDefaults: UserDefaults

    init(modelManager: LocalModelManager? = nil, modelError: String? = nil,
         mcpAccess: MCPAccess = MCPAccess(), bundleURL: URL = Bundle.main.bundleURL,
         languageDefaults: UserDefaults = .standard, limitsDefaults: UserDefaults = .standard,
         themeDefaults: UserDefaults = .standard, shortcutDefaults: UserDefaults = .standard,
         launchLanguage: LanguagePreference = L10n.preference, frameAutosaveName: String? = "BufferaSettingsWindow") {
        self.limitsDefaults = limitsDefaults
        settings = SettingsContentController(modelManager: modelManager, modelError: modelError,
                                             mcpAccess: mcpAccess, bundleURL: bundleURL, languageDefaults: languageDefaults,
                                             limitsDefaults: limitsDefaults, themeDefaults: themeDefaults, shortcutDefaults: shortcutDefaults, launchLanguage: launchLanguage)
        let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("Настройки \(BrandIdentity.name)")
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
            if !window.setFrameUsingName(frameAutosaveName) ||
                !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
                window.center()
            }
        } else {
            window.center()
        }
        // Preserve page space when migrating frames from before the support footer.
        if window.contentLayoutRect.height < 620 {
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: 620, height: 620))
            let bottom = window.screen?.visibleFrame.minY ?? 0
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: max(bottom, top - window.frame.height)))
        }
        super.init(window: window)
        window.contentViewController = settings
        settings.onShortcutsChange = { [weak self] value in
            guard let apply = self?.onShortcutsChange else { throw ShortcutPreferenceError.unavailable }
            try apply(value)
        }
        settings.onAppearanceChange = { [weak self] value in self?.onAppearanceChange?(value) }
        settings.onShowSetup = { [weak self] in self?.onShowSetup?() }
        settings.onRestart = { [weak self] in self?.onRestart?() }
        settings.onLimitsChange = { [weak self] value in self?.onLimitsChange?(value) }
        settings.onSecretHistoryChange = { [weak self] mode, completion in
            guard let apply = self?.onSecretHistoryChange else { completion(.failure(SecretStorageError.keyUnavailable)); return }
            apply(mode, completion)
        }
        settings.onRevealData = { [weak self] in self?.onRevealData?() }
        settings.onCopyMCPConfiguration = { [weak self] configuration in
            guard let copy = self?.onCopyMCPConfiguration else { throw MCPSettingsError.copyUnavailable }
            try copy(configuration)
        }
        settings.onCheckModel = { [weak self] role in self?.onCheckModel?(role) }
        settings.onCancelModelCheck = { [weak self] role in self?.onCancelModelCheck?(role) }
        settings.onWillDisableOrRemoveModel = { [weak self] role in self?.onWillDisableOrRemoveModel?(role) }
        settings.onRetryEmbeddingIndex = { [weak self] in self?.onRetryEmbeddingIndex?() }
        settings.onOnlyPrepareOnExternalPowerChanged = { [weak self] in
            self?.onOnlyPrepareOnExternalPowerChanged?($0)
        }
        settings.onContinueEmbeddingPreparation = { [weak self] in self?.onContinueEmbeddingPreparation?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        settings.updateAppearance(HistoryAppearance.load())
        settings.updateLimits(HistoryLimits.load(from: limitsDefaults))
        settings.refreshLanguage()
        settings.refreshTheme()
        settings.refreshShortcuts()
        settings.refreshMCPAccess()
        settings.refreshSecrets()
        settings.refreshTextFileNaming()
        settings.refreshModels()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showFeatures() {
        show()
        settings.showFeatures()
    }

    func updateAppearance(_ value: HistoryAppearance) { settings.updateAppearance(value) }
    func updateModels(_ snapshots: [LocalModelSnapshot]) { settings.updateModels(snapshots) }
    func updateModelCheck(role: ModelRole, status: String, running: Bool) {
        settings.updateModelCheck(role: role, status: status, running: running)
    }
    func updateEmbeddingIndex(status: String, progress: Double?, canRetry: Bool, canContinueNow: Bool = false) {
        settings.updateEmbeddingIndex(status: status, progress: progress, canRetry: canRetry,
                                      canContinueNow: canContinueNow)
    }
    func updateBackgroundPreparation(onlyOnExternalPower: Bool) {
        settings.updateBackgroundPreparation(onlyOnExternalPower: onlyOnExternalPower)
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
    var onShortcutsChange: ((ShortcutPreferences) throws -> Void)?
    var onAppearanceChange: ((HistoryAppearance) -> Void)?
    var onLimitsChange: ((HistoryLimits) -> Void)?
    var onSecretHistoryChange: SecretHistorySettingsView.Apply?
    var onShowSetup: (() -> Void)?
    var onRestart: (() -> Void)?
    var onRevealData: (() -> Void)?
    var onCopyMCPConfiguration: ((String) throws -> Void)?
    var onCheckModel: ((ModelRole) -> Void)?
    var onCancelModelCheck: ((ModelRole) -> Void)?
    var onWillDisableOrRemoveModel: ((ModelRole) -> Void)?
    var onRetryEmbeddingIndex: (() -> Void)?
    var onOnlyPrepareOnExternalPowerChanged: ((Bool) -> Void)?
    var onContinueEmbeddingPreparation: (() -> Void)?

    private let shortcutDefaults: UserDefaults
    private let shortcutSettings: ShortcutSettingsView
    private let mcp: MCPSettingsView
    private let secrets: SecretHistorySettingsView
    private let models: ModelSettingsView
    private var appearance = HistoryAppearance.load()
    private var limits: HistoryLimits
    private let limitsDefaults: UserDefaults
    private let mode = NSPopUpButton()
    private let columns = NSPopUpButton()
    private let rows = NSPopUpButton()
    private let language = NSPopUpButton()
    private let theme = NSPopUpButton()
    private let themeDefaults: UserDefaults
    private let languageDefaults: UserDefaults
    private let launchLanguage: LanguagePreference
    private let restartNotice = NSStackView()
    private let sidebar = NSButton(checkboxWithTitle: L10n.text("Показывать боковую панель с фильтрами"), target: nil, action: nil)
    private let count = NSPopUpButton()
    private let textFileNaming = NSPopUpButton()
    private let bytes = NSSlider()
    private let byteValue = NSTextField(labelWithString: "")
    private var countValues = HistoryLimits.countChoices
    private let tabs = NSSegmentedControl(labels: [L10n.text("Вид"), L10n.text("История"), L10n.text("Клавиши"), "MCP", L10n.text("Поиск и ответы")], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let saveNotice = NSTextField(labelWithString: "")
    private let body = NSView()
    private var pages: [NSView] = []

    init(modelManager: LocalModelManager?, modelError: String?, mcpAccess: MCPAccess, bundleURL: URL,
         languageDefaults: UserDefaults, limitsDefaults: UserDefaults, themeDefaults: UserDefaults, shortcutDefaults: UserDefaults, launchLanguage: LanguagePreference) {
        self.shortcutDefaults = shortcutDefaults
        shortcutSettings = ShortcutSettingsView(value: .load(from: shortcutDefaults))
        self.limitsDefaults = limitsDefaults
        secrets = SecretHistorySettingsView(defaults: limitsDefaults)
        self.limits = HistoryLimits.load(from: limitsDefaults)
        self.launchLanguage = launchLanguage
        self.languageDefaults = languageDefaults
        self.themeDefaults = themeDefaults
        mcp = MCPSettingsView(access: mcpAccess, bundleURL: bundleURL)
        models = ModelSettingsView(manager: modelManager, unavailableMessage: modelError)
        super.init(nibName: nil, bundle: nil)
        secrets.onApply = { [weak self] mode, completion in
            guard let apply = self?.onSecretHistoryChange else { completion(.failure(SecretStorageError.keyUnavailable)); return }
            apply(mode, completion)
        }
        shortcutSettings.onApply = { [weak self] value in
            guard let self, let apply = self.onShortcutsChange else { throw ShortcutPreferenceError.unavailable }
            try apply(value)
            try value.save(to: self.shortcutDefaults)
        }
        mcp.onCopyConfiguration = { [weak self] configuration in
            guard let copy = self?.onCopyMCPConfiguration else { throw MCPSettingsError.copyUnavailable }
            try copy(configuration)
        }
        models.onCheck = { [weak self] role in self?.onCheckModel?(role) }
        models.onCancelCheck = { [weak self] role in self?.onCancelModelCheck?(role) }
        models.onWillDisableOrRemove = { [weak self] role in self?.onWillDisableOrRemoveModel?(role) }
        models.onRetryEmbeddingIndex = { [weak self] in self?.onRetryEmbeddingIndex?() }
        models.onOnlyPrepareOnExternalPowerChanged = { [weak self] in
            self?.onOnlyPrepareOnExternalPowerChanged?($0)
        }
        models.onContinueEmbeddingPreparation = { [weak self] in self?.onContinueEmbeddingPreparation?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshShortcuts() { shortcutSettings.refresh(.load(from: shortcutDefaults)) }
    func refreshMCPAccess() { mcp.refresh() }
    func refreshModels() { models.refresh() }
    func showFeatures() {
        _ = view
        tabs.selectedSegment = 4
        presentPage(4)
    }
    func updateModels(_ snapshots: [LocalModelSnapshot]) { models.update(snapshots) }
    func updateModelCheck(role: ModelRole, status: String, running: Bool) {
        models.updateCheck(role: role, status: status, running: running)
    }
    func updateEmbeddingIndex(status: String, progress: Double?, canRetry: Bool, canContinueNow: Bool = false) {
        models.updateEmbeddingIndex(status: status, progress: progress, canRetry: canRetry,
                                    canContinueNow: canContinueNow)
    }
    func updateBackgroundPreparation(onlyOnExternalPower: Bool) {
        models.updateBackgroundPreparation(onlyOnExternalPower: onlyOnExternalPower)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 620))
        let icon = NSImageView(image: BrandIdentity.appIcon(size: 64))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(BrandIdentity.name)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let name = label(BrandIdentity.name, size: 25, weight: .bold)
        let tagline = label(L10n.text("Держит всё, что ты копируешь."), size: 12, color: .secondaryLabelColor)
        let identity = vertical([name, tagline], spacing: 3)
        let header = NSStackView(views: [icon, identity])
        header.orientation = .horizontal; header.spacing = 14; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded
        tabs.controlSize = .regular
        tabs.target = self; tabs.action = #selector(changeTab)
        tabs.setAccessibilityLabel(L10n.text("Раздел настроек"))
        for index in 0..<tabs.segmentCount { tabs.setWidth(index == 4 ? 130 : 92, forSegment: index) }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        let setupButton = NSButton(title: L10n.text("Пройти настройку заново…"), target: self, action: #selector(showSetup))
        setupButton.bezelStyle = .inline
        saveNotice.font = .systemFont(ofSize: 11); saveNotice.textColor = .tertiaryLabelColor
        let footerNotes = vertical([saveNotice, setupButton], spacing: 3)
        let footer = NSStackView(views: [footerNotes, NSView(), SupportBufferaButton()])
        footer.spacing = 18
        footer.alignment = .centerY
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
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        pages = [appearancePage(), SetupUI.scroll(historyPage()), SetupUI.scroll(keyboardPage()), SetupUI.scroll(mcp), models]
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
        count.removeAllItems(); count.addItems(withTitles: countValues.map { $0.formatted(.number.locale(L10n.locale)) })
        count.selectItem(at: countValues.firstIndex(of: value.maxCount) ?? 0)
        bytes.doubleValue = Double(value.maxBytes) / Double(HistoryLimits.bytesPerGigabyte)
        byteValue.stringValue = L10n.text("\((Double(value.maxBytes) / Double(HistoryLimits.bytesPerGigabyte)).formatted(.number.locale(L10n.locale))) ГБ")
        bytes.setAccessibilityValueDescription(byteValue.stringValue)
    }

    func refreshLanguage() {
        language.selectItem(at: LanguagePreference.allCases.firstIndex(of: .load(from: languageDefaults)) ?? 0)
        restartNotice.isHidden = LanguagePreference.load(from: languageDefaults) == launchLanguage
    }

    func refreshTheme() {
        theme.selectItem(at: InterfaceTheme.allCases.firstIndex(of: .load(from: themeDefaults)) ?? 0)
    }

    private func appearancePage() -> NSView {
        theme.addItems(withTitles: InterfaceTheme.allCases.map(\.title))
        theme.identifier = NSUserInterfaceItemIdentifier("settings.theme")
        configure(theme, label: L10n.text("Тема"), action: #selector(themeChanged))
        refreshTheme()
        language.addItems(withTitles: LanguagePreference.allCases.map(\.title))
        language.selectItem(at: LanguagePreference.allCases.firstIndex(of: .load(from: languageDefaults)) ?? 0)
        language.identifier = NSUserInterfaceItemIdentifier("settings.language")
        configure(language, label: L10n.text("Язык интерфейса"), action: #selector(languageChanged))
        mode.addItems(withTitles: HistoryAppearance.Mode.allCases.map(\.title))
        columns.addItems(withTitles: [L10n.text("1 — список"), L10n.text("2 — сетка"), L10n.text("3 — сетка"), L10n.text("4 — сетка")])
        rows.addItems(withTitles: (3...12).map(String.init))
        for (button, title) in [(mode, L10n.text("Расположение окна")), (columns, L10n.text("Количество колонок")), (rows, L10n.text("Видимых строк"))] {
            configure(button, label: title, action: #selector(appearanceChanged))
        }
        sidebar.target = self; sidebar.action = #selector(appearanceChanged)
        sidebar.font = .systemFont(ofSize: 12)
        let grid = form([
            [label(L10n.text("Тема")), theme],
            [label(L10n.text("Расположение")), mode],
            [label(L10n.text("Карточки")), columns],
            [label(L10n.text("Видимых строк")), rows],
            [label(L10n.text("Язык")), language]
        ])
        let note = paragraph(L10n.text("Одна колонка — список, несколько — сетка. Число строк задаёт высоту карточек. В боковой панели это максимальная высота: короткие записи занимают меньше места."))
        let tip = info(symbol: "sidebar.left", title: L10n.text("У каждого вида — своё место"),
                       text: L10n.text("Обычное окно можно перемещать и менять в размере. Боковая панель выезжает у выбранного края экрана."))
        let languageNote = paragraph(L10n.text("Язык применяется после перезапуска Buffera. «Системный» следует предпочитаемым языкам macOS; если русский и английский отсутствуют, используется английский."))
        let restart = NSButton(title: L10n.text("Перезапустить Buffera"), target: self, action: #selector(restartApp))
        restart.bezelStyle = .rounded
        restart.identifier = NSUserInterfaceItemIdentifier("settings.restart")
        restartNotice.identifier = NSUserInterfaceItemIdentifier("settings.restartNotice")
        restartNotice.orientation = .horizontal
        restartNotice.alignment = .centerY
        restartNotice.spacing = 10
        restartNotice.addArrangedSubview(paragraph(L10n.text("Язык изменится после перезапуска")))
        restartNotice.addArrangedSubview(restart)
        refreshLanguage()
        let page = vertical([grid, languageNote, restartNotice, sidebar, note, tip], spacing: 12)
        for child in [grid, languageNote, note, tip] { child.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        return page
    }

    func refreshSecrets() { secrets.refresh() }

    func refreshTextFileNaming() {
        textFileNaming.selectItem(at: TextFileNaming.allCases.firstIndex(of: .load(from: limitsDefaults)) ?? 0)
    }

    @objc private func textFileNamingChanged() {
        guard TextFileNaming.allCases.indices.contains(textFileNaming.indexOfSelectedItem) else { return }
        limitsDefaults.set(TextFileNaming.allCases[textFileNaming.indexOfSelectedItem].rawValue,
                           forKey: TextFileNaming.preferenceKey)
    }

    private func historyPage() -> NSView {
        configure(textFileNaming, label: L10n.text("Имя текстового файла"), action: #selector(textFileNamingChanged))
        textFileNaming.identifier = NSUserInterfaceItemIdentifier("settings.textFileNaming")
        textFileNaming.addItems(withTitles: TextFileNaming.allCases.map(\.title))
        refreshTextFileNaming()
        let namingNote = paragraph(L10n.text("Для «Как файл .txt» и «Как файл .md». Если первая строка не подходит для имени, используется время копирования."))
        let naming = vertical([label(L10n.text("Имя текстового файла")), textFileNaming, namingNote], spacing: 8)
        namingNote.widthAnchor.constraint(equalTo: naming.widthAnchor).isActive = true
        configure(count, label: L10n.text("Лимит записей"), action: #selector(countLimitChanged))
        count.identifier = NSUserInterfaceItemIdentifier("settings.countLimit")
        bytes.minValue = Double(HistoryLimits.byteRange.lowerBound / HistoryLimits.bytesPerGigabyte)
        bytes.maxValue = Double(HistoryLimits.byteRange.upperBound / HistoryLimits.bytesPerGigabyte)
        bytes.numberOfTickMarks = Int(bytes.maxValue - bytes.minValue) + 1
        bytes.allowsTickMarkValuesOnly = true
        bytes.isContinuous = true
        bytes.target = self; bytes.action = #selector(byteLimitChanged)
        bytes.identifier = NSUserInterfaceItemIdentifier("settings.byteLimit")
        bytes.setAccessibilityLabel(L10n.text("Лимит объёма истории"))
        byteValue.identifier = NSUserInterfaceItemIdentifier("settings.byteLimitValue")
        byteValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        byteValue.alignment = .right
        byteValue.setContentHuggingPriority(.required, for: .horizontal)
        byteValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        let sizeControl = NSStackView(views: [bytes, byteValue])
        sizeControl.orientation = .horizontal; sizeControl.alignment = .centerY; sizeControl.spacing = 10
        sizeControl.widthAnchor.constraint(equalToConstant: 232).isActive = true
        bytes.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let grid = form([[label(L10n.text("Количество записей")), count], [label(L10n.text("Объём истории")), sizeControl]])
        let note = paragraph(L10n.text("При следующем копировании старые записи сверх лимита будут удалены. Избранное сохраняется и не входит в эти лимиты."))
        let ocr = info(symbol: "text.viewfinder", title: L10n.text("Текст на картинках тоже находится"),
                       text: L10n.text("Распознавание работает в фоне на Mac. Русский и английский текст участвуют в обычном поиске; скрытые записи пропускаются."))
        let folder = NSButton(title: L10n.text("Открыть папку данных"), target: self, action: #selector(revealData))
        folder.bezelStyle = .rounded
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folder.imagePosition = .imageLeading
        let storage = paragraph(L10n.text("История хранится локально. Ключ шифрования секретов хранится в Связке ключей macOS. При потере ключа восстановить секреты не получится."))
        let page = vertical([naming, secrets, grid, note, ocr, folder, storage], spacing: 14)
        for child in [naming, secrets, grid, note, ocr, storage] { child.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        return page
    }

    private func keyboardPage() -> NSView {
        let navigation = [
            (L10n.text("Выбрать запись"), "↑ ↓ ← →"),
            (L10n.text("Первые девять записей"), "⌘1–9"),
            (L10n.text("Перейти к поиску"), "⌘F"),
            (L10n.text("Вся история"), "⌘0"),
            (L10n.text("Боковая панель"), "⌘⌥S"),
            (L10n.text("Настройки"), "⌘,"),
            (L10n.text("Закрыть просмотр / окно"), "Esc")
        ]
        let actions = ClipCardAction.allCases.map { ($0.title, $0.shortcut) }
        let left = shortcutGroup(L10n.text("Навигация"), entries: navigation)
        let right = shortcutGroup(L10n.text("Выбранная запись"), entries: actions)
        let groups = NSStackView(views: [left, right])
        groups.orientation = .horizontal; groups.alignment = .top; groups.spacing = 24
        groups.distribution = .fillEqually
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        let page = vertical([shortcutSettings, groups], spacing: 18)
        groups.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        shortcutSettings.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
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
        saveNotice.stringValue = index == 2 ? L10n.text("Сочетания применяются без перезапуска") : L10n.text("Изменения сохраняются сразу")
        for view in body.subviews { view.removeFromSuperview() }
        let page = pages[index]
        page.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            page.topAnchor.constraint(equalTo: body.topAnchor),
            page === models || page is NSScrollView
                ? page.bottomAnchor.constraint(equalTo: body.bottomAnchor)
                : page.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor)
        ])
    }

    @objc private func showSetup() { onShowSetup?() }

    @objc private func changeTab() { presentPage(tabs.selectedSegment) }

    @objc private func themeChanged() {
        let choices = InterfaceTheme.allCases
        guard choices.indices.contains(theme.indexOfSelectedItem) else { return }
        let preference = choices[theme.indexOfSelectedItem]
        preference.save(to: themeDefaults)
        preference.apply()
    }

    @objc private func languageChanged() {
        let choices = LanguagePreference.allCases
        guard choices.indices.contains(language.indexOfSelectedItem) else { return }
        choices[language.indexOfSelectedItem].save(to: languageDefaults)
        refreshLanguage()
    }

    @objc private func restartApp() { onRestart?() }

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

    @objc private func countLimitChanged() {
        guard countValues.indices.contains(count.indexOfSelectedItem) else { return }
        saveLimits(HistoryLimits(maxCount: countValues[count.indexOfSelectedItem], maxBytes: limits.maxBytes))
    }

    @objc private func byteLimitChanged() {
        saveLimits(HistoryLimits(maxCount: limits.maxCount,
                                 maxBytes: Int(bytes.doubleValue.rounded()) * HistoryLimits.bytesPerGigabyte))
    }

    private func saveLimits(_ next: HistoryLimits) {
        guard limits != next else { return }
        updateLimits(next)
        next.save(to: limitsDefaults)
        onLimitsChange?(next)
    }

    @objc private func revealData() { onRevealData?() }
}
