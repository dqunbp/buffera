import AppKit
import BufferaLocalization

/// Read-only help anchored to the setting it explains.
class SettingsHelpButton: NSButton {
    private let makeContent: () -> SettingsHelpView
    let helpPopover = NSPopover()

    init(id: String, title: String, makeContent: @escaping () -> SettingsHelpView) {
        self.makeContent = makeContent
        super.init(frame: .zero)
        bezelStyle = .helpButton
        self.title = ""
        identifier = .init(id)
        toolTip = L10n.text("Пояснение: \(title)")
        setAccessibilityLabel(toolTip)
        target = self
        action = #selector(toggleHelp)
        helpPopover.behavior = .transient
        helpPopover.animates = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { helpPopover.close() }
    }

    @objc private func toggleHelp() {
        if helpPopover.isShown { helpPopover.close(); return }
        guard window?.isVisible == true else { return }
        let content = makeContent()
        content.onDismiss = { [weak self] in self?.helpPopover.close() }
        let controller = NSViewController()
        controller.view = content
        helpPopover.contentViewController = controller
        helpPopover.contentSize = content.fittingSize
        helpPopover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
        content.window?.makeKey()
        content.window?.makeFirstResponder(content)
    }
}

class SettingsHelpView: NSView {
    var onDismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    init(id: String, title: String, detail: String, examples: NSView? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        identifier = .init(id)
        let heading = SetupUI.text(title, size: 15, bold: true)
        heading.identifier = .init("settingsHelp.title")
        let explanation = SetupUI.text(detail, size: 12)
        explanation.identifier = .init("settingsHelp.detail")
        explanation.textColor = .secondaryLabelColor
        heading.preferredMaxLayoutWidth = 384
        explanation.preferredMaxLayoutWidth = 384

        let stack = SetupUI.column([heading, examples, explanation].compactMap { $0 }, spacing: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 420),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18)
        ])
        setFrameSize(fittingSize)
        layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
