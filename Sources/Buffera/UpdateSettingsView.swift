import AppKit
import BufferaCore
import BufferaLocalization
import BufferaUpdates

final class UpdateSettingsView: NSStackView {
    var onCheck: (() -> Void)?
    var onAutomaticChange: ((Bool) -> Void)?
    var onOpenRelease: (() -> Void)?
    var onSkip: (() -> Void)?
    var onInstall: (() -> Void)?

    private let status = SetupUI.text("", size: 17, bold: true)
    private let detail = SetupUI.text("", size: 12)
    private let automatic = NSButton(checkboxWithTitle: L10n.text("Проверять обновления автоматически"), target: nil, action: nil)
    private let checkButton = NSButton(title: L10n.text("Проверить обновления…"), target: nil, action: nil)
    private let openButton = NSButton(title: L10n.text("Открыть релиз"), target: nil, action: nil)
    private let installButton = NSButton(title: L10n.text("Обновить…"), target: nil, action: nil)
    private let skipButton = NSButton(title: L10n.text("Пропустить эту версию"), target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 18
        identifier = .init("settings.updates")
        status.identifier = .init("updates.status")
        detail.identifier = .init("updates.detail")
        detail.textColor = .secondaryLabelColor
        automatic.identifier = .init("updates.automatic")
        automatic.target = self; automatic.action = #selector(toggleAutomatic)
        for (button, name, action) in [(checkButton, "check", #selector(checkNow)),
                                       (installButton, "install", #selector(installRelease)),
                                       (openButton, "open", #selector(openRelease)),
                                       (skipButton, "skip", #selector(skipRelease))] {
            button.identifier = .init("updates.\(name)")
            button.bezelStyle = .rounded; button.target = self; button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        let installed = SetupUI.text(L10n.text("Установлена Buffera \(AppVersion.version) (сборка \(AppVersion.build))."), size: 12)
        installed.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [installButton, openButton, skipButton])
        actions.spacing = 10; actions.alignment = .centerY
        let summary = SetupUI.card([installed, status, detail, actions], tinted: true)
        let note = SetupUI.text(L10n.text("Фоновая проверка выполняется не чаще раза в сутки. История буфера не передаётся. Новая версия отмечается двумя красными точками на значке Buffera и пунктом в его меню."), size: 12)
        note.textColor = .secondaryLabelColor
        for child in [summary, automatic, note, checkButton] { addArrangedSubview(child) }
        summary.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        render(automatic: true, checking: false, release: nil, skipped: false, outcome: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(automatic enabled: Bool, checking: Bool, release: ReleaseUpdate?, skipped: Bool,
                outcome: UpdateCheckOutcome?) {
        automatic.state = enabled ? .on : .off
        checkButton.isEnabled = !checking
        checkButton.title = checking ? L10n.text("Проверка обновлений…") : L10n.text("Проверить обновления…")
        openButton.isHidden = release == nil
        installButton.isHidden = release == nil
        skipButton.isHidden = release == nil
        skipButton.isEnabled = !skipped
        skipButton.title = skipped ? L10n.text("Версия пропущена") : L10n.text("Пропустить эту версию")
        status.stringValue = release.map { L10n.text("Доступна Buffera \($0.version.description)") }
            ?? L10n.text("Обновления Buffera")
        detail.stringValue = release == nil
            ? L10n.text("Проверьте, доступна ли новая версия Buffera.")
            : L10n.text("Нажмите «Обновить…», чтобы скачать и установить новую версию. Buffera перезапустится после подтверждения. После обновления перезапустите подключённый MCP-процесс.")
        if checking {
            if release == nil { status.stringValue = L10n.text("Проверка обновлений…") }
            return
        }
        switch outcome {
        case .upToDate: status.stringValue = L10n.text("У вас актуальная версия"); detail.stringValue = ""
        case .noCompatibleRelease:
            status.stringValue = L10n.text("Подходящий релиз не найден")
            detail.stringValue = L10n.text("На GitHub пока нет готового стабильного релиза для этого Mac.")
        case .failed(.rateLimited):
            if release == nil { status.stringValue = L10n.text("Проверка временно недоступна") }
            detail.stringValue = L10n.text("GitHub ограничил частоту запросов. Повторите проверку позже.")
        case .failed(.unavailable), .failed(.invalidResponse):
            if release == nil { status.stringValue = L10n.text("Не удалось проверить обновления") }
            detail.stringValue = L10n.text("Проверьте подключение к интернету и повторите попытку позже. Приложение продолжает работать.")
        default: break
        }
    }

    func showBrowserError() { detail.stringValue = L10n.text("Не удалось открыть браузер") }
    func showInstallationError() {
        detail.stringValue = L10n.text("Не удалось начать обновление. Повторите попытку или откройте релиз для ручной установки.")
    }
    func renderInstallation(busy: Bool) {
        installButton.isEnabled = !busy
        installButton.title = busy ? L10n.text("Обновление…") : L10n.text("Обновить…")
    }
    @objc private func installRelease() { onInstall?() }
    @objc private func checkNow() { onCheck?() }
    @objc private func toggleAutomatic() { onAutomaticChange?(automatic.state == .on) }
    @objc private func openRelease() { onOpenRelease?() }
    @objc private func skipRelease() { onSkip?() }
}
