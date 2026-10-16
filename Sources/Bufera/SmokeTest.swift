import AppKit
import BuferaCore

func runSmokeTest() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let service = ClipboardService(pasteboard: pasteboard)
    let payload = ClipPayload(items: [
        [Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("Проверка буфера".utf8)),
         Representation(type: "app.bufera.custom", data: Data([0, 1, 2, 255]))],
        [Representation(type: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data("file:///tmp/example.txt".utf8))]
    ])
    try service.restore(payload)
    guard try service.capture()?.payload == payload else { throw HistoryError.invalidPayload }
    var captured = false
    service.onCapture = { _ in captured = true }
    service.poll()
    guard !captured else { throw HistoryError.database("Own write was captured") }
    pasteboard.clearContents(); pasteboard.setString("Новое копирование", forType: .string)
    service.poll()
    guard captured else { throw HistoryError.database("External write was not captured") }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let imagePayload = ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.tiff.rawValue, data: bitmap.tiffRepresentation!)]])
    guard let (png, ext) = ClipboardService.imageData(imagePayload), ext == "png", NSBitmapImageRep(data: png)?.pixelsWide == 2 else { throw ClipboardFailure.noImage }
    pasteboard.clearContents()
    let sensitive = NSPasteboardItem(); sensitive.setString("secret", forType: .string)
    sensitive.setString("", forType: .init("org.nspasteboard.ConcealedType")); pasteboard.writeObjects([sensitive])
    guard try service.capture() == nil else { throw HistoryError.database("Sensitive entry captured") }
}
