import AppKit
import BufferaLocalization

enum AppearanceHelpTopic: String, CaseIterable {
    case placement, columns, rows

    var title: String {
        switch self {
        case .placement: return L10n.text("Расположение окна")
        case .columns: return L10n.text("Количество колонок")
        case .rows: return L10n.text("Видимых строк")
        }
    }

    var detail: String {
        switch self {
        case .placement:
            return L10n.text("Обычное окно можно перемещать и менять в размере. Боковая панель появляется сразу у выбранного края экрана.")
        case .columns:
            return L10n.text("Колонки — это карточки рядом друг с другом: одна даёт список, несколько — сетку. Если окно узкое, колонок будет меньше.")
        case .rows:
            return L10n.text("Меньше строк — выше карточки и больше текста. Больше строк — компактнее карточки. В боковой панели короткие записи могут быть ниже.")
        }
    }
}

/// Read-only help anchored to the setting it explains.
final class AppearanceHelpButton: NSButton {
    let topic: AppearanceHelpTopic
    let helpPopover = NSPopover()

    init(topic: AppearanceHelpTopic) {
        self.topic = topic
        super.init(frame: .zero)
        bezelStyle = .helpButton
        title = ""
        identifier = .init("settings.appearanceHelp." + topic.rawValue)
        toolTip = L10n.text("Пояснение: \(topic.title)")
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
        let content = AppearanceHelpView(topic: topic)
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

/// Schematic examples, independent of the user's history and saved preferences.
final class AppearanceHelpView: NSView {
    var onDismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    init(topic: AppearanceHelpTopic) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        identifier = .init("appearanceHelp." + topic.rawValue)
        let title = SetupUI.text(topic.title, size: 15, bold: true)
        title.identifier = .init("appearanceHelp.title")
        let detail = SetupUI.text(topic.detail, size: 12)
        detail.identifier = .init("appearanceHelp.detail")
        detail.textColor = .secondaryLabelColor
        title.preferredMaxLayoutWidth = 384
        detail.preferredMaxLayoutWidth = 384

        let examples: [(AppearanceHelpDiagram.Kind, String)]
        switch topic {
        case .placement:
            examples = HistoryAppearance.Mode.allCases.map { (.placement($0), $0.title) }
        case .columns:
            examples = [(.cards(columns: 1, rows: 3), L10n.text("1 — список")),
                        (.cards(columns: 3, rows: 3), L10n.text("3 — сетка"))]
        case .rows:
            examples = [(.cards(columns: 1, rows: 3), L10n.text("Видимых строк: \(3)")),
                        (.cards(columns: 1, rows: 9), L10n.text("Видимых строк: \(9)"))]
        }
        let exampleWidth = (384 - CGFloat(examples.count - 1) * 12) / CGFloat(examples.count)
        let illustrations = examples.enumerated().map { index, example -> NSView in
            let diagram = AppearanceHelpDiagram(kind: example.0)
            diagram.identifier = .init("appearanceHelp.diagram.\(index)")
            diagram.heightAnchor.constraint(equalToConstant: 112).isActive = true
            let caption = SetupUI.text(example.1, size: 11, bold: true)
            caption.identifier = .init("appearanceHelp.caption.\(index)")
            caption.alignment = .center
            caption.preferredMaxLayoutWidth = exampleWidth
            let column = SetupUI.column([diagram, caption], spacing: 8)
            column.widthAnchor.constraint(equalToConstant: exampleWidth).isActive = true
            return column
        }
        let row = NSStackView(views: illustrations)
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        let stack = SetupUI.column([title, row, detail], spacing: 14)
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

private final class AppearanceHelpDiagram: NSView {
    enum Kind {
        case placement(HistoryAppearance.Mode)
        case cards(columns: Int, rows: Int)
    }

    private let kind: Kind
    override var isFlipped: Bool { true }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        // The adjacent caption and explanation describe this decorative diagram.
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 1, dy: 4)
        switch kind {
        case .placement(let mode):
            box(frame, fill: .controlBackgroundColor, stroke: .separatorColor, radius: 6)
            NSColor.separatorColor.setFill()
            NSRect(x: frame.minX + 6, y: frame.minY + 7, width: frame.width - 12, height: 2).fill()
            let desktop = frame.insetBy(dx: 7, dy: 15)
            let panel: NSRect
            switch mode {
            case .floating:
                panel = NSRect(x: desktop.minX + desktop.width * 0.15, y: desktop.minY + 8,
                               width: desktop.width * 0.7, height: desktop.height - 16)
            case .left:
                panel = NSRect(x: desktop.minX, y: desktop.minY,
                               width: desktop.width * 0.5, height: desktop.height)
            case .right:
                panel = NSRect(x: desktop.midX, y: desktop.minY,
                               width: desktop.width * 0.5, height: desktop.height)
            }
            drawCards(in: panel, columns: 1, rows: 3)
        case .cards(let columns, let rows):
            drawCards(in: frame, columns: columns, rows: rows)
        }
    }

    private func drawCards(in frame: NSRect, columns: Int, rows: Int) {
        box(frame, fill: .windowBackgroundColor, stroke: BrandIdentity.accentColor, radius: 5)
        let area = frame.insetBy(dx: 5, dy: 5)
        let gap: CGFloat = rows > 3 ? 3 : 5
        let width = (area.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let height = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let card = NSRect(x: area.minX + CGFloat(column) * (width + gap),
                                  y: area.minY + CGFloat(row) * (height + gap),
                                  width: width, height: height)
                box(card, fill: BrandIdentity.accentColor.withAlphaComponent(0.12),
                    stroke: BrandIdentity.accentColor.withAlphaComponent(0.45), radius: 2)
                if height > 14 {
                    BrandIdentity.accentColor.withAlphaComponent(0.55).setFill()
                    NSRect(x: card.minX + 4, y: card.minY + 5, width: max(3, width * 0.6), height: 2).fill()
                    if height > 23 {
                        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                        NSRect(x: card.minX + 4, y: card.minY + 11, width: max(3, width * 0.75), height: 2).fill()
                    }
                }
            }
        }
    }

    private func box(_ rect: NSRect, fill: NSColor, stroke: NSColor, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill(); path.fill()
        stroke.setStroke(); path.lineWidth = 1; path.stroke()
    }
}
