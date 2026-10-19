import AppKit

@main
enum GenerateAppIcon {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "BufferaIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected the output iconset directory"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let image = BrandIdentity.appIcon(size: CGFloat(pixels))
                let png = try rasterize(image, pixels: pixels)
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }

        // Also keep a large preview and the actual menu-bar mark for visual inspection.
        try rasterize(BrandIdentity.appIcon(size: 512), pixels: 512)
            .write(to: directory.deletingLastPathComponent().appendingPathComponent("branding-preview.png"))
        try rasterize(BrandIdentity.menuBarIcon(), width: 20, height: 18)
            .write(to: directory.deletingLastPathComponent().appendingPathComponent("branding-menu.png"))
    }

    private static func rasterize(_ image: NSImage, pixels: Int) throws -> Data {
        try rasterize(image, width: pixels, height: pixels)
    }

    private static func rasterize(_ image: NSImage, width: Int, height: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "BufferaIcon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create an icon bitmap"])
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BufferaIcon", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode an icon bitmap"])
        }
        return data
    }
}
