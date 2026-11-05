import AppKit
import BufferaLocalization

/// Native, keyboard-focusable sidebar buttons; stable page indices preserve deep links.
final class SettingsNavigation: NSControl {
    private let titles = [L10n.text("Вид"), L10n.text("История"), L10n.text("Клавиши"), "MCP",
                          L10n.text("ИИ"), L10n.text("Обновления"), L10n.text("Основные")]
    static let displayOrder = [6, 4, 0, 1, 2, 3, 5]
    private var buttons: [NSButton] = []
    var selectedSegment = 6 { didSet { updateSelection() } }
    var segmentCount: Int { titles.count }
    func label(forSegment index: Int) -> String? { titles[index] }
    func width(forSegment index: Int) -> CGFloat { buttons[index].bounds.width - 46 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 13)
        let symbols = ["paintbrush", "clock", "keyboard", "puzzlepiece.extension", "sparkles", "arrow.down.circle", "gearshape"]
        buttons = titles.enumerated().map { index, title in
            let button = SettingsNavigationButton(title: title, target: self, action: #selector(selectPage(_:)))
            button.cell = SettingsNavigationCell(textCell: title)
            button.target = self; button.action = #selector(selectPage(_:))
            button.tag = index
            button.identifier = .init("settings.section.\(index)")
            button.setButtonType(.toggle)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: index == 4 ? .semibold : .regular)
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return button
        }
        let column = SetupUI.column(Self.displayOrder.map { buttons[$0] }, spacing: 4)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren(Self.displayOrder.map { buttons[$0] })
        setAccessibilityLabel(L10n.text("Раздел настроек"))
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateSelection() {
        for button in buttons {
            button.state = button.tag == selectedSegment ? .on : .off
            button.contentTintColor = button.tag == selectedSegment || button.tag == 4 ? BrandIdentity.accentColor : .labelColor
            button.needsDisplay = true
        }
    }
    @objc private func selectPage(_ sender: NSButton) {
        selectedSegment = sender.tag
        sendAction(action, to: target)
    }
}

private final class SettingsNavigationButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Native cell rendering and hit targets, with room around the icon on both states.
private final class SettingsNavigationCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: 10, dy: 0), in: controlView)
    }
}
