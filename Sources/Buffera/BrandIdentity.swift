import AppKit

/// One vector mark shared by the menu bar, settings, and the generated application icon.
enum BrandIdentity {
    static let name = "Buffera"

    /// A restrained version of the app icon's violet, with readable active
    /// controls in both appearances. Native label colors remain unchanged.
    static let accentColor = NSColor(name: NSColor.Name("BufferaAccent")) { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua,
                                           .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
        case .darkAqua, .accessibilityHighContrastDarkAqua:
            return NSColor(srgbRed: 0.72, green: 0.59, blue: 0.87, alpha: 1)
        default:
            return NSColor(srgbRed: 0.46, green: 0.31, blue: 0.65, alpha: 1)
        }
    }

    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            drawMark(in: NSRect(x: 0, y: 0, width: 20, height: 18), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }

    /// Draw separately from the template mark so macOS preserves the red color.
    static func updateDotsImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            drawUpdateDots()
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }

    /// Menu images cannot mix template tinting with red dots, so draw the mark
    /// with the current menu text color and avoid caching an earlier appearance.
    static func updateMenuIcon(highlighted: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            drawMark(in: NSRect(x: 0, y: 0, width: 20, height: 18),
                     color: highlighted ? .selectedMenuItemTextColor : .labelColor)
            drawUpdateDots()
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }

    private static func drawUpdateDots() {
        NSColor.systemRed.setFill()
        // Sit on the stroke, just outside each semicircle's lower extremum.
        for x in [5.3, 14.7] {
            NSBezierPath(ovalIn: NSRect(x: x - 2, y: 4.04 - 2, width: 4, height: 4)).fill()
        }
    }

    static func appIcon(size: CGFloat = 128) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }

            let tile = bounds.insetBy(dx: size * 0.065, dy: size * 0.065)
            let shape = NSBezierPath(roundedRect: tile,
                                     xRadius: size * 0.195, yRadius: size * 0.195)
            let colors = [
                NSColor(srgbRed: 0.31, green: 0.20, blue: 0.63, alpha: 1),
                NSColor(srgbRed: 0.58, green: 0.41, blue: 0.88, alpha: 1),
            ]
            NSGradient(colors: colors)?.draw(in: shape, angle: 65)

            NSColor.white.withAlphaComponent(0.16).setStroke()
            shape.lineWidth = max(0.5, size * 0.002)
            shape.stroke()

            let mark = NSRect(x: size * 0.13, y: size * 0.16,
                              width: size * 0.74, height: size * 0.666)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(srgbRed: 0.12, green: 0.04, blue: 0.28, alpha: 0.25)
            shadow.shadowBlurRadius = size * 0.018
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.009)
            shadow.set()
            drawMark(in: mark, color: NSColor.white.withAlphaComponent(0.97))
            return true
        }
        image.accessibilityDescription = name
        return image
    }

    private static func drawMark(in bounds: NSRect, color: NSColor) {
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: bounds.minX + x / 20 * bounds.width,
                    y: bounds.minY + y / 18 * bounds.height)
        }

        // Two soft, open bowls. No dots or literal illustration: the silhouette is the joke.
        let path = NSBezierPath()
        path.move(to: point(3.0, 13.8))
        path.curve(to: point(5.9, 4.0),
                   controlPoint1: point(0.9, 7.9), controlPoint2: point(2.4, 4.0))
        path.curve(to: point(10.0, 10.2),
                   controlPoint1: point(8.5, 4.0), controlPoint2: point(10.0, 6.2))
        path.curve(to: point(14.1, 4.0),
                   controlPoint1: point(10.0, 6.2), controlPoint2: point(11.5, 4.0))
        path.curve(to: point(17.0, 13.8),
                   controlPoint1: point(17.6, 4.0), controlPoint2: point(19.1, 7.9))
        path.lineWidth = bounds.width / 20 * 1.75
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}
