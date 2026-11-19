import AppKit
import BufferaModels
import BufferaLocalization

/// The introductory step is deliberately shown every time; it performs no model actions.
final class ModelConnectionSheet: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let source: ModelSourceView
    private let intro = NSStackView()
    private let next = NSButton()
    private let cancel = NSButton()
    private let stack = NSStackView()
    var onClose: (() -> Void)?

    init(manager: LocalModelManager, role: ModelRole, discovery: @escaping () -> [ExternalModels.Candidate]) {
        source = ModelSourceView(manager: manager, role: role, discovery: discovery)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = L10n.text("Подключить свою модель")
        let title = NSTextField(wrappingLabelWithString: L10n.text("Подключить уже скачанную модель"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("Если вы уже скачивали совместимую модель, например через Google Foresight, Buffera может использовать тот же файл. Повторно скачивать его не нужно, копия на диске не создаётся."))
        let fallback = NSTextField(wrappingLabelWithString: L10n.text("Если вы не знаете, есть ли у вас такая модель, закройте это окно и нажмите «Скачать модель» в настройках — Buffera скачает подходящую автоматически."))
        intro.orientation = .vertical
        intro.alignment = .leading
        intro.spacing = 16
        for view in [title, explanation, fallback] {
            intro.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: intro.widthAnchor).isActive = true
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        explanation.font = .systemFont(ofSize: 13)
        fallback.font = .systemFont(ofSize: 13)
        fallback.textColor = .secondaryLabelColor
        next.title = L10n.text("Далее")
        next.bezelStyle = .rounded
        next.target = self
        next.action = #selector(showSelection)
        next.keyEquivalent = "\r"
        next.identifier = .init("models.connection.next")
        cancel.title = L10n.text("Отмена")
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(close)
        cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = .init("models.connection.cancel")
        source.connectButton.isHidden = true
        let actions = NSStackView(views: [cancel, NSView(), next, source.connectButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        source.isHidden = true
        for view in [intro, source, actions] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24)
        ])
        source.onNeedsResize = { [weak self] in self?.resize() }
        source.onConnected = { [weak self] in self?.close() }
        source.onBusyChanged = { [weak self] busy in self?.cancel.isEnabled = !busy }
        resize()
    }

    @objc private func showSelection() {
        intro.isHidden = true
        source.isHidden = false
        next.isHidden = true
        source.connectButton.isHidden = false
        next.keyEquivalent = ""
        source.discover()
        resize()
    }

    private func resize() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 570, height: stack.fittingSize.height + 48))
    }

    @objc private func close() {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        onClose?()
    }
}
