import AppKit
import BufferaCore
import BufferaLocalization

final class GeneralSettingsView: NSStackView {
    private let preferences: AppPreferences
    private let login = NSButton(checkboxWithTitle: L10n.text("Запускать при входе в систему"), target: nil, action: nil)
    private let menuBar = NSButton(checkboxWithTitle: L10n.text("Показывать значок в строке меню"), target: nil, action: nil)
    private let status = SetupUI.text("", size: 12)
    private let approval = NSButton(title: L10n.text("Открыть настройки входа macOS"), target: nil, action: nil)
    private var activationObserver: NSObjectProtocol?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 18
        login.allowsMixedState = true
        login.identifier = .init("settings.launchAtLogin")
        menuBar.identifier = .init("settings.menuBarIcon")
        status.identifier = .init("settings.loginStatus")
        approval.identifier = .init("settings.loginApproval")
        login.target = self; login.action = #selector(changeLogin)
        menuBar.target = self; menuBar.action = #selector(changeMenuBar)
        approval.target = self; approval.action = #selector(openApproval)
        approval.bezelStyle = .rounded
        let access = SetupUI.text(L10n.text("Без значка откройте историю сочетанием клавиш или запустите Buffera снова, чтобы открыть настройки."), size: 12)
        access.textColor = .secondaryLabelColor
        let startup = SetupUI.card([SetupUI.text(L10n.text("Запуск и доступ"), bold: true), login, status, approval, menuBar, access])
        let version = SetupUI.text(L10n.text("Версия \(AppVersion.version) · сборка \(AppVersion.build)"), size: 13)
        version.identifier = .init("settings.version")
        version.isSelectable = true
        let report = SupportBufferaButton(support: .reportIssue)
        let reportNote = SetupUI.text(L10n.text("Откроется черновик GitHub Issue с версией Buffera, сборкой, версией macOS и архитектурой. Содержимое буфера и логи не добавляются."), size: 12)
        reportNote.textColor = .secondaryLabelColor
        let about = SetupUI.card([SetupUI.text(L10n.text("О приложении"), bold: true), version, report, reportNote])
        for card in [startup, about] {
            addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        refresh()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }

    func insertLanguageCard(_ card: NSView) {
        insertArrangedSubview(card, at: 1)
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func refresh() {
        menuBar.state = preferences.showsMenuBarIcon ? .on : .off
        let value = preferences.loginStatus()
        login.state = value == .enabled ? .on : value == .requiresApproval ? .mixed : .off
        approval.isHidden = value != .requiresApproval
        status.stringValue = value == .requiresApproval
            ? L10n.text("Разрешите автозапуск Buffera в настройках входа macOS.")
            : value == .notFound ? L10n.text("Не удалось определить состояние автозапуска.") : ""
        status.textColor = .secondaryLabelColor
        status.isHidden = status.stringValue.isEmpty
    }

    @objc private func changeLogin() {
        let current = preferences.loginStatus()
        let enabled = current != .enabled && current != .requiresApproval
        do {
            try preferences.setLoginEnabled(enabled)
            refresh()
        } catch {
            refresh()
            status.stringValue = L10n.text("Не удалось изменить автозапуск: \(error.localizedDescription)")
            status.textColor = .systemRed
            status.isHidden = false
        }
    }

    @objc private func changeMenuBar() { preferences.showsMenuBarIcon = menuBar.state == .on }
    @objc private func openApproval() { preferences.openLoginSettings() }
}
