import AppKit
import BufferaLocalization

/// The settings button and menu items share one external destination and action.
final class SupportBuffera: NSObject {
    static let shared = SupportBuffera()
    static let url = URL(string: "https://web.tribute.tg/d/SHI")!
    static var title: String { L10n.text("Поддержать Buffera 💜") }

    @objc func openDonationPage(_ sender: Any?) {
        guard !NSWorkspace.shared.open(Self.url) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("Не удалось открыть браузер")
        alert.informativeText = L10n.text("Откройте ссылку для поддержки Buffera в браузере: \(Self.url.absoluteString)")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openDonationPage(_:)), keyEquivalent: "")
        item.target = shared
        return item
    }
}

/// A quiet secondary action with native button semantics and keyboard focus.
final class SupportBufferaButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init() {
        super.init(frame: .zero)
        title = SupportBuffera.title
        target = SupportBuffera.shared
        action = #selector(SupportBuffera.openDonationPage(_:))
        setButtonType(.momentaryPushIn)
        isBordered = false
        font = .systemFont(ofSize: 11.5, weight: .regular)
        focusRingType = .exterior
        identifier = NSUserInterfaceItemIdentifier("settings.support")
        toolTip = L10n.text("Поддержать разработку через Tribute — откроется в браузере")
        setAccessibilityLabel(title)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 24, height: 30)
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 9, yRadius: 9)
        BrandIdentity.accentColor.withAlphaComponent(isHighlighted ? 0.16 : (hovered ? 0.1 : 0.045)).setFill()
        shape.fill()
        (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor :
            BrandIdentity.accentColor.withAlphaComponent(hovered ? 0.3 : 0.16)).setStroke()
        shape.lineWidth = 0.75
        shape.stroke()
        let text = NSAttributedString(string: title, attributes: [
            .font: font!, .foregroundColor: NSColor.secondaryLabelColor
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 9, yRadius: 9).fill()
    }
}
