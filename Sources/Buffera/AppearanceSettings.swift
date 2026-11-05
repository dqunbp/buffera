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
    var onTemporaryHistoryChange: ((Bool) -> Void)?
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

    init(modelManager: LocalModelManager? = nil, modelError: String? = nil, appPreferences: AppPreferences = AppPreferences(),
         mcpAccess: MCPAccess = MCPAccess(), updateSettings: NSView = UpdateSettingsView(), bundleURL: URL = Bundle.main.bundleURL,
         languageDefaults: UserDefaults = .standard, limitsDefaults: UserDefaults = .standard,
         themeDefaults: UserDefaults = .standard, shortcutDefaults: UserDefaults = .standard,
         launchLanguage: LanguagePreference = L10n.preference, frameAutosaveName: String? = "BufferaSettingsWindow") {
        self.limitsDefaults = limitsDefaults
        settings = SettingsContentController(modelManager: modelManager, modelError: modelError, appPreferences: appPreferences,
                                             mcpAccess: mcpAccess, updateSettings: updateSettings, bundleURL: bundleURL, languageDefaults: languageDefaults,
                                             limitsDefaults: limitsDefaults, themeDefaults: themeDefaults, shortcutDefaults: shortcutDefaults, launchLanguage: launchLanguage)
        let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 740),
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
        // Preserve room for translated labels and the grouped history settings.
        if window.contentLayoutRect.width < 920 || window.contentLayoutRect.height < 740 {
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: 920, height: 740))
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
        settings.onTemporaryHistoryChange = { [weak self] value in self?.onTemporaryHistoryChange?(value) }
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
        settings.refreshTemporaryHistory()
        settings.refreshHistoryReset()
        settings.refreshModels()
        settings.refreshGeneral()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showFeatures() {
        show()
        settings.showFeatures()
    }

    func selectUpdates() { settings.selectUpdates() }
    func selectSection(_ index: Int) { settings.selectSection(index) }

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
    var onTemporaryHistoryChange: ((Bool) -> Void)?
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
    private let temporaryHistory: TemporaryHistorySettingsView
    private let historyReset: HistoryResetSettingsView
    private let models: ModelSettingsView
    private let updateSettings: NSView
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
    private let bytes = NSSlider()
    private let byteValue = NSTextField(labelWithString: "")
    private var countValues = HistoryLimits.countChoices
    private let tabs = SettingsNavigation(frame: .zero)
    private let pageTitle = NSTextField(labelWithString: "")
    private let general: GeneralSettingsView
    private let saveNotice = NSTextField(labelWithString: "")
    private let body = NSView()
    private var pages: [NSView] = []

    init(modelManager: LocalModelManager?, modelError: String?, appPreferences: AppPreferences, mcpAccess: MCPAccess, updateSettings: NSView, bundleURL: URL,
         languageDefaults: UserDefaults, limitsDefaults: UserDefaults, themeDefaults: UserDefaults, shortcutDefaults: UserDefaults, launchLanguage: LanguagePreference) {
        general = GeneralSettingsView(preferences: appPreferences)
        self.shortcutDefaults = shortcutDefaults
        self.updateSettings = updateSettings
        shortcutSettings = ShortcutSettingsView(value: .load(from: shortcutDefaults))
        self.limitsDefaults = limitsDefaults
        secrets = SecretHistorySettingsView(defaults: limitsDefaults)
        temporaryHistory = TemporaryHistorySettingsView(defaults: limitsDefaults)
        historyReset = HistoryResetSettingsView(defaults: limitsDefaults)
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
        temporaryHistory.onChange = { [weak self] value in self?.onTemporaryHistoryChange?(value) }
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

    func refreshGeneral() { general.refresh() }
    func selectSection(_ index: Int) {
        _ = view
        tabs.selectedSegment = index
        presentPage(index)
    }
    func refreshShortcuts() { shortcutSettings.refresh(.load(from: shortcutDefaults)) }
    func refreshMCPAccess() { mcp.refresh() }
    func refreshModels() { models.refresh() }
    func showFeatures() {
        _ = view
        tabs.selectedSegment = 4
        presentPage(4)
    }
    func selectUpdates() {
        _ = view
        tabs.selectedSegment = 5
        presentPage(5)
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
        let root = SettingsBackground(frame: NSRect(x: 0, y: 0, width: 920, height: 740))
        let icon = NSImageView(image: BrandIdentity.appIcon(size: 64))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(BrandIdentity.name)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let name = label(BrandIdentity.name, size: 25, weight: .bold)
        let tagline = label(L10n.text("Держит всё, что ты копируешь."), size: 12, color: .secondaryLabelColor)
        let identity = vertical([name, tagline], spacing: 3)
        identity.identifier = NSUserInterfaceItemIdentifier("settings.identity")
        let header = NSStackView(views: [icon, identity])
        header.orientation = .horizontal; header.spacing = 14; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        let githubStar = SupportBufferaButton(support: .githubStar)
        githubStar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(githubStar)

        tabs.target = self; tabs.action = #selector(changeTab)
        let rail = NSVisualEffectView()
        rail.material = .sidebar; rail.blendingMode = .withinWindow
        rail.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rail, positioned: .below, relativeTo: header)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(tabs)
        pageTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        pageTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageTitle)
        body.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(body)

        saveNotice.font = .systemFont(ofSize: 11); saveNotice.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [saveNotice, NSView(), SupportBufferaButton()])
        footer.spacing = 18
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.topAnchor.constraint(equalTo: root.topAnchor), rail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 180),
            tabs.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -10),
            tabs.topAnchor.constraint(equalTo: rail.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 204),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            githubStar.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 20),
            githubStar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            githubStar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pageTitle.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            pageTitle.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 28),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 204),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: pageTitle.bottomAnchor, constant: 18),
            body.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        general.insertLanguageCard(languageCard())
        pages = [SetupUI.scroll(appearancePage()), SetupUI.scroll(historyPage()), SetupUI.scroll(keyboardPage()), SetupUI.scroll(mcp), models, SetupUI.scroll(updateSettings), SetupUI.scroll(general)]
        view = root
        updateAppearance(appearance)
        updateLimits(limits)
        presentPage(6)
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

    private func languageCard() -> NSView {
        language.addItems(withTitles: LanguagePreference.allCases.map(\.title))
        language.selectItem(at: LanguagePreference.allCases.firstIndex(of: .load(from: languageDefaults)) ?? 0)
        language.identifier = NSUserInterfaceItemIdentifier("settings.language")
        configure(language, label: L10n.text("Язык интерфейса"), action: #selector(languageChanged))
        let languageNote = paragraph(L10n.text("Язык применяется после перезапуска Buffera. «Системный» выбирает первый поддерживаемый язык из предпочтений macOS; если подходящего нет, используется английский."))
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
        return SetupUI.card([form([[label(L10n.text("Язык интерфейса")), language]]), languageNote, restartNotice])
    }

    private func appearancePage() -> NSView {
        theme.addItems(withTitles: InterfaceTheme.allCases.map(\.title))
        theme.identifier = NSUserInterfaceItemIdentifier("settings.theme")
        configure(theme, label: L10n.text("Тема"), action: #selector(themeChanged))
        refreshTheme()
        mode.addItems(withTitles: HistoryAppearance.Mode.allCases.map(\.title))
        columns.addItems(withTitles: [L10n.text("1 — список"), L10n.text("2 — сетка"), L10n.text("3 — сетка"), L10n.text("4 — сетка")])
        rows.addItems(withTitles: (3...12).map(String.init))
        for (button, title) in [(mode, L10n.text("Расположение окна")), (columns, L10n.text("Количество колонок")), (rows, L10n.text("Видимых строк"))] {
            configure(button, label: title, action: #selector(appearanceChanged))
        }
        sidebar.target = self; sidebar.action = #selector(appearanceChanged)
        sidebar.font = .systemFont(ofSize: 12)
        let grid = form([
            [label(L10n.text("Тема")), theme, NSView()],
            [label(L10n.text("Расположение")), mode, AppearanceHelpButton(topic: .placement)],
            [label(L10n.text("Карточки")), columns, AppearanceHelpButton(topic: .columns)],
            [label(L10n.text("Видимых строк")), rows, AppearanceHelpButton(topic: .rows)]
        ])
        let setupButton = NSButton(title: L10n.text("Пройти настройку заново…"), target: self, action: #selector(showSetup))
        setupButton.bezelStyle = .inline
        setupButton.identifier = NSUserInterfaceItemIdentifier("settings.showSetup")
        let setupNote = paragraph(L10n.text("Откроет тот же мастер настройки, что и при первом запуске Buffera, с вашими текущими параметрами."))
        setupNote.identifier = NSUserInterfaceItemIdentifier("settings.setupNote")
        let setup = vertical([setupButton, setupNote], spacing: 4)
        setupNote.widthAnchor.constraint(equalTo: setup.widthAnchor).isActive = true
        let appearanceCard = SetupUI.card([grid, sidebar])
        let setupCard = SetupUI.card([setup])
        let page = vertical([appearanceCard, setupCard], spacing: 16)
        for card in [appearanceCard, setupCard] { card.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }

        return page
    }

    func refreshSecrets() { secrets.refresh() }
    func refreshTemporaryHistory() { temporaryHistory.refresh() }
    func refreshHistoryReset() { historyReset.refresh() }

    private func historyPage() -> NSView {
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
        let folder = NSButton(title: L10n.text("Открыть папку данных"), target: self, action: #selector(revealData))
        folder.identifier = NSUserInterfaceItemIdentifier("settings.revealData")
        folder.bezelStyle = .rounded
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folder.imagePosition = .imageLeading
        let storage = paragraph(L10n.text("История хранится локально. Ключ шифрования секретов хранится в Связке ключей macOS. При потере ключа восстановить секреты не получится."))
        let retention = vertical([label(L10n.text("Хранение записей"), size: 13, weight: .semibold),
                                  grid, note, temporaryHistory, folder], spacing: 10)
        retention.identifier = NSUserInterfaceItemIdentifier("settings.history.storage")
        for child in [grid, note, temporaryHistory] { child.widthAnchor.constraint(equalTo: retention.widthAnchor).isActive = true }
        let privacy = vertical([secrets, storage], spacing: 8)
        privacy.identifier = NSUserInterfaceItemIdentifier("settings.history.secrets")
        for child in [secrets, storage] { child.widthAnchor.constraint(equalTo: privacy.widthAnchor).isActive = true }
        let reopening = vertical([label(L10n.text("При открытии окна"), size: 13, weight: .semibold), historyReset], spacing: 10)
        reopening.identifier = NSUserInterfaceItemIdentifier("settings.history.reopening")
        historyReset.widthAnchor.constraint(equalTo: reopening.widthAnchor).isActive = true
        let page = vertical([SetupUI.card([retention]), SetupUI.card([privacy]), SetupUI.card([reopening])], spacing: 16)
        for child in page.arrangedSubviews { child.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
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
        pageTitle.stringValue = tabs.label(forSegment: index) ?? ""
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

private final class SettingsBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
