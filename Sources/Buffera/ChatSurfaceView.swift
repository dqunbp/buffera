import AppKit

/// Shared chat surfaces respond to appearance and macOS accessibility preferences.
final class ChatSurfaceView: NSView {
    enum Style { case answer, question, composer, source }
    private let style: Style
    var focused = false { didSet { updateSurface() } }

    init(_ style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = style == .source ? 12 : 20
        layer?.cornerCurve = .continuous
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateSurface),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateSurface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    @objc private func updateSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let opaque = HistorySurfaceAppearance.requiresOpaque
            let base = NSColor.controlBackgroundColor
            let tint: CGFloat = style == .question ? 0.18 : (style == .source ? 0.06 : 0)
            let fill = base.blended(withFraction: tint, of: BrandIdentity.accentColor) ?? base
            layer?.backgroundColor = fill.withAlphaComponent(opaque ? 1 : (style == .composer ? 0.78 : 0.64)).cgColor
            let edge = focused ? BrandIdentity.accentColor : NSColor.separatorColor
            layer?.borderColor = edge.withAlphaComponent(focused || opaque ? 0.75 : 0.3).cgColor
            layer?.borderWidth = focused ? 1.5 : (opaque ? 1 : 0.5)
            layer?.shadowColor = BrandIdentity.accentColor.cgColor
            layer?.shadowOpacity = style == .composer && focused && !opaque ? 0.12 : 0
            layer?.shadowRadius = 12
            layer?.shadowOffset = .zero
        }
    }
}
