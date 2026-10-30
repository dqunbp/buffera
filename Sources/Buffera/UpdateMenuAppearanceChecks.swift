import AppKit
import BufferaCore

@MainActor func checkUpdateMenuAppearance(_ indicator: UpdateMenuIndicator, menu: NSMenu) throws {
    let regular = indicator.menuItem.image!
    for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true), (.aqua, false)] {
        var result: Result<Void, Error>!
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = Result {
                // Reuse the same image across themes to catch stale black/white caches.
                try verify(render(regular), lightMark: dark)
                indicator.menu(menu, willHighlight: indicator.menuItem)
                try verify(render(indicator.menuItem.image!), lightMark: true)
                indicator.menu(menu, willHighlight: nil)
                try verify(render(indicator.menuItem.image!), lightMark: dark)
                if let directory = ProcessInfo.processInfo.environment["BUFFERA_UPDATE_PREVIEW_DIR"] {
                    for highlighted in [false, true] {
                        indicator.menu(menu, willHighlight: highlighted ? indicator.menuItem : nil)
                        let icon = indicator.menuItem.image!
                        let title = indicator.menuItem.title
                        let preview = NSImage(size: NSSize(width: 320, height: 38), flipped: false) { bounds in
                            (highlighted ? NSColor.selectedContentBackgroundColor : .windowBackgroundColor).setFill()
                            bounds.fill()
                            icon.draw(in: NSRect(x: 10, y: 10, width: 20, height: 18))
                            (title as NSString).draw(at: NSPoint(x: 40, y: 11), withAttributes: [
                                .font: NSFont.menuFont(ofSize: 13),
                                .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : .labelColor
                            ])
                            return true
                        }
                        let bitmap = NSBitmapImageRep(data: preview.tiffRepresentation!)!
                        let file = "update-menu-\(dark ? "dark" : "light")\(highlighted ? "-selected" : "").png"
                        try bitmap.representation(using: .png, properties: [:])!.write(
                            to: URL(fileURLWithPath: directory).appendingPathComponent(file))
                    }
                }
            }
        }
        try result.get()
    }
    indicator.menuNeedsUpdate(menu)
}

private func render(_ image: NSImage) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 36,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let bounds = NSRect(x: 0, y: 0, width: 40, height: 36)
    NSGraphicsContext.current!.cgContext.clear(bounds)
    image.draw(in: bounds)
    return bitmap
}

private func verify(_ bitmap: NSBitmapImageRep, lightMark: Bool) throws {
    var markPixels = 0, leftRed = 0, rightRed = 0
    var brightness = 0.0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            // Native menu text colors may be translucent even at full strength.
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
            if color.redComponent > color.greenComponent + 0.25 && color.redComponent > color.blueComponent + 0.25 {
                if x < bitmap.pixelsWide / 2 { leftRed += 1 } else { rightRed += 1 }
            } else if abs(color.redComponent - color.greenComponent) < 0.08 && abs(color.redComponent - color.blueComponent) < 0.08 {
                markPixels += 1
                brightness += color.redComponent
            }
        }
    }
    guard markPixels > 20, leftRed > 0, rightRed > 0 else {
        throw HistoryError.database("Update menu icon must contain the complete mark and both red dots: mark=\(markPixels), left=\(leftRed), right=\(rightRed), light=\(lightMark)")
    }
    let average = brightness / Double(markPixels)
    guard lightMark ? average > 0.7 : average < 0.3 else {
        throw HistoryError.database("Update menu icon has insufficient contrast for its appearance/highlight state")
    }
}
