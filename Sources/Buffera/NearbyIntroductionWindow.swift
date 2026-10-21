import AppKit
import BufferaLocalization

final class NearbyIntroductionWindow: NSWindowController, NSWindowDelegate {
    static let preferenceKey = "nearby.hideIntroduction"
    var onDismiss: ((Bool) -> Void)?
    private let defaults: UserDefaults
    private let remember = NSButton(checkboxWithTitle: L10n.text("Больше не показывать автоматически"), target: nil, action: nil)

    init(explainingOnly: Bool = false, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 490),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("Что копировал до и после")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        remember.state = .on; remember.identifier = .init("nearby.remember")
        let confirm = NSButton(title: explainingOnly ? L10n.text("Понятно") : L10n.text("Показать до и после"), target: self, action: #selector(accept))
        confirm.bezelStyle = .rounded; confirm.keyEquivalent = "\r"; confirm.identifier = .init("nearby.accept")
        let cancel = NSButton(title: L10n.text("Отмена"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = .init("nearby.cancel"); cancel.isHidden = explainingOnly
        let buttons = NSStackView(views: [cancel, NSView(), confirm])
        let content = SetupUI.column([
            SetupUI.text(L10n.text("Вспомните, что было рядом"), size: 23, bold: true),
            SetupUI.text(L10n.text("Откройте записи, которые вы копировали перед выбранной записью и сразу после неё. Так проще восстановить контекст работы.")),
            SetupUI.card([
                SetupUI.text(L10n.text("Например, вы нашли договор:"), size: 12),
                SetupUI.text(L10n.text("14:29 · Реквизиты компании")),
                SetupUI.text(L10n.text("14:32 · Договор — исходная запись"), bold: true),
                SetupUI.text(L10n.text("14:35 · Срок отправки"))
            ], tinted: true),
            SetupUI.text(L10n.text("Записи идут по времени копирования, из всей истории — независимо от поиска и фильтров. Это помогает найти связанные детали. Кнопка возврата восстановит прежний список."), size: 12),
            remember, buttons
        ], spacing: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    @objc private func accept() {
        defaults.set(remember.state == .on, forKey: Self.preferenceKey)
        dismiss(accepted: true)
    }
    @objc private func cancel() { dismiss(accepted: false) }
    private func dismiss(accepted: Bool) {
        let callback = onDismiss; onDismiss = nil
        close(); callback?(accepted)
    }
}
