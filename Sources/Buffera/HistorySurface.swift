import AppKit

enum HistorySurfaceAppearance {
    static var requiresOpaque: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

/// A translucent fill keeps the stationary dots legible without blurring them away.
final class HistorySidebarSurface: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
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
            layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(HistorySurfaceAppearance.requiresOpaque ? 1 : 0.38).cgColor
        }
    }
}

/// A quiet, stationary texture underneath the history, independent of scrolling.
final class HistoryBackdropView: NSVisualEffectView {
    private let texture = HistoryDotTexture()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        texture.frame = bounds
        texture.autoresizingMask = [.width, .height]
        addSubview(texture)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshTexture),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTexture()
    }

    @objc private func refreshTexture() { texture.needsDisplay = true }
}

private final class HistoryDotTexture: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let accessible = HistorySurfaceAppearance.requiresOpaque
        let base = NSColor(srgbRed: dark ? 0.105 : 0.96, green: dark ? 0.105 : 0.95,
                           blue: dark ? 0.115 : 0.975, alpha: accessible ? 1 : 0.72)
        base.setFill()
        dirtyRect.fill()
        guard !accessible else { return }
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.12 : 0.09).setFill()
        let spacing: CGFloat = 24
        let dots = NSBezierPath()
        for x in stride(from: floor(dirtyRect.minX / spacing) * spacing + 12,
                        through: dirtyRect.maxX, by: spacing) {
            for y in stride(from: floor(dirtyRect.minY / spacing) * spacing + 12,
                            through: dirtyRect.maxY, by: spacing) {
                dots.appendOval(in: NSRect(x: x, y: y, width: 1.6, height: 1.6))
            }
        }
        dots.fill()
    }
}

/// Controls sit in native glass; readable clip content stays on calm surfaces.
final class HistoryGlassToolbar: NSView {
    private let content = NSView()
    private let fallback = NSVisualEffectView()
    private var glass: NSView?

    init(controls: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        fallback.material = .headerView
        fallback.blendingMode = .withinWindow
        fallback.state = .active
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = 18
        fallback.layer?.cornerCurve = .continuous
        fallback.layer?.masksToBounds = true
        addSubview(fallback)
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .regular
            effect.cornerRadius = 18
            glass = effect
            addSubview(effect)
        }
        controls.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 44)
        ])
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMaterial),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateMaterial()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func layout() {
        super.layout()
        fallback.frame = bounds
        glass?.frame = bounds
        content.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterial()
    }

    @objc private func updateMaterial() {
        let accessible = HistorySurfaceAppearance.requiresOpaque
        let useGlass = glass != nil && !accessible
        if #available(macOS 26.0, *), let effect = glass as? NSGlassEffectView {
            if useGlass {
                if effect.contentView !== content { effect.contentView = content }
            } else if effect.contentView != nil {
                effect.contentView = nil
            }
        }
        if !useGlass && content.superview !== fallback { fallback.addSubview(content) }
        glass?.isHidden = !useGlass
        fallback.isHidden = useGlass
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fallback.layer?.backgroundColor = accessible ? NSColor.windowBackgroundColor.cgColor : nil
            fallback.layer?.borderColor = NSColor.separatorColor.cgColor
            fallback.layer?.borderWidth = accessible ? 1 : 0.5
        }
        needsLayout = true
    }
}

/// Native button behavior and accessibility, with a small branded glass capsule.
final class HistoryAskButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovered = false

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        isBordered = false
        controlSize = .small
        font = .systemFont(ofSize: 12, weight: .semibold)
        image = BrandIdentity.menuBarIcon()
        image?.size = NSSize(width: 18, height: 16)
        imagePosition = .imageLeading
        contentTintColor = .white
        (cell as? NSButtonCell)?.highlightsBy = []
        updateLabel()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshSurface),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((cell?.cellSize.width ?? 64) + 20), height: 28)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isEnabled: Bool {
        didSet { updateLabel(); needsDisplay = true }
    }

    private func updateLabel() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.72)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSurface()
    }

    @objc private func refreshSurface() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let opaque = HistorySurfaceAppearance.requiresOpaque
        let pressed = cell?.isHighlighted == true
        let highlight: CGFloat = hovered && isEnabled && !pressed ? 0.035 : 0
        let alpha: CGFloat = opaque ? 1 : (isEnabled ? 0.94 : 0.58)
        let top = NSColor(srgbRed: 0.55 + highlight, green: 0.38 + highlight,
                          blue: 0.75 + highlight, alpha: alpha)
        let bottom = NSColor(srgbRed: 0.37, green: 0.23, blue: 0.58, alpha: alpha)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        if opaque || pressed {
            bottom.setFill()
            shape.fill()
        } else {
            NSGradient(starting: bottom, ending: top)?.draw(in: shape, angle: 90)
        }
        NSColor.white.withAlphaComponent(opaque ? 0.65 : 0.3).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        // Use our disabled palette instead of AppKit's dark disabled text over violet.
        // Only the drawing copy is enabled; the actual control stays noninteractive.
        let interior = cell?.copy() as? NSButtonCell
        interior?.isEnabled = true
        interior?.drawInterior(withFrame: bounds.insetBy(dx: 10, dy: 0), in: self)
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }
}
