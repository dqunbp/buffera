import AppKit
import BufferaLocalization

/// Settings and menu actions share external-link handling and browser failure UI.
final class SupportBuffera: NSObject {
    enum Destination {
        case donation, githubStar

        var url: URL {
            switch self {
            case .donation: URL(string: "https://web.tribute.tg/d/SHI")!
            case .githubStar: URL(string: "https://github.com/dqunbp/buffera")!
            }
        }

        var title: String {
            switch self {
            case .donation: L10n.text("Поддержать Buffera 💜")
            case .githubStar: "☆ " + L10n.text("Поставить звезду на GitHub")
            }
        }

        var toolTip: String {
            switch self {
            case .donation: L10n.text("Поддержать разработку через Tribute — откроется в браузере")
            case .githubStar: L10n.text("Нравится Buffera? Поставьте звезду на GitHub — откроется в браузере")
            }
        }

        var identifier: String {
            switch self {
            case .donation: "settings.support"
            case .githubStar: "settings.githubStar"
            }
        }
    }

    static let shared = SupportBuffera(destination: .donation)
    static let githubStar = SupportBuffera(destination: .githubStar)
    let destination: Destination
    private let openURL: (URL) -> Bool
    private let presentAlert: (NSAlert) -> Void

    init(destination: Destination, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         presentAlert: @escaping (NSAlert) -> Void = { alert in
             NSApp.activate(ignoringOtherApps: true)
             alert.runModal()
         }) {
        self.destination = destination
        self.openURL = openURL
        self.presentAlert = presentAlert
        super.init()
    }

    @objc func openPage(_ sender: Any?) {
        guard !openURL(destination.url) else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("Не удалось открыть браузер")
        alert.informativeText = L10n.text("Откройте ссылку для поддержки Buffera в браузере: \(destination.url.absoluteString)")
        presentAlert(alert)
    }

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: shared.destination.title, action: #selector(openPage(_:)), keyEquivalent: "")
        item.target = shared
        return item
    }
}

/// A quiet secondary action with native button semantics and keyboard focus.
final class SupportBufferaButton: NSButton {
    private let support: SupportBuffera
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init(support: SupportBuffera = .shared) {
        self.support = support
        super.init(frame: .zero)
        title = support.destination.title
        target = support
        action = #selector(SupportBuffera.openPage(_:))
        setButtonType(.momentaryPushIn)
        isBordered = false
        font = .systemFont(ofSize: 11.5, weight: .regular)
        focusRingType = .exterior
        identifier = NSUserInterfaceItemIdentifier(support.destination.identifier)
        toolTip = support.destination.toolTip
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
