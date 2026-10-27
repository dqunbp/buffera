import AppKit
import BufferaCore

var count = 0
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "ThumbnailCacheChecks", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: message]) }
    count += 1
    print("PASS", message)
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
NSApp.finishLaunching()
let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("BufferaThumbnailChecks-\(UUID())")
try manager.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: root) }
let directory = root.appendingPathComponent("cache")
let original = root.appendingPathComponent("original.png")
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: original)
let pixels = Representation(type: "public.png", data: png)
let file = Representation(type: "public.file-url", data: Data(original.absoluteString.utf8))
let fileOnly = ClipPayload(items: [[file]])
let embedded = ClipPayload(items: [[pixels, file]])
let cache = ThumbnailCache(directory: directory)

try check(ClipboardService.thumbnail(fileOnly) == nil,
          "automatic thumbnail does not open an existing readable original")
try check(cache.thumbnail(id: 1, payload: fileOnly, isConcealed: false) == nil,
          "cold cache for legacy file-only history does not read the original")
try check(cache.thumbnail(id: 2, payload: embedded, isConcealed: false)?.size.width == 320,
          "embedded clipboard pixels generate a bounded cached thumbnail")
guard case .image(let preview) = ClipPreviewContent.decode(fileOnly, kind: .file) else {
    fatalError("Explicit file preview failed")
}
cache.save(preview, id: 1, payload: fileOnly, isConcealed: false)
try manager.removeItem(at: original)
let reopened = ThumbnailCache(directory: directory)
try check(reopened.thumbnail(id: 1, payload: fileOnly, isConcealed: false)?.size.width == 320,
          "file thumbnail survives relaunch and removal of the original")
try check(reopened.thumbnail(id: 2, payload: embedded, isConcealed: false) != nil,
          "embedded thumbnail survives relaunch")
let other = ClipPayload(items: [[Representation(type: "public.file-url",
    data: Data(root.appendingPathComponent("other.png").absoluteString.utf8))]])
try check(reopened.thumbnail(id: 1, payload: other, isConcealed: false) == nil,
          "reused database ID cannot display a different payload's cached image")

// A corrupt cache must not silently fall back to a now-readable original.
try png.write(to: original)
let cachedFile = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .first { $0.lastPathComponent.hasPrefix("1-") }!
try Data("corrupt".utf8).write(to: cachedFile)
try check(reopened.thumbnail(id: 1, payload: fileOnly, isConcealed: false) == nil,
          "corrupt cache never falls back to the original file")
try manager.removeItem(at: cachedFile)
try check(reopened.thumbnail(id: 1, payload: fileOnly, isConcealed: false) == nil,
          "evicted cache never falls back to the original file")
reopened.save(preview, id: 1, payload: fileOnly, isConcealed: false)
try check(reopened.thumbnail(id: 1, payload: fileOnly, isConcealed: true) == nil,
          "concealed record cannot read a cached thumbnail")
try check(!manager.fileExists(atPath: cachedFile.path), "concealing removes the disk thumbnail")
reopened.save(preview, id: 1, payload: fileOnly, isConcealed: true)
try check(!manager.fileExists(atPath: cachedFile.path), "concealed pixels cannot be written to cache")
reopened.prune { _ in false }
try check(try manager.contentsOfDirectory(atPath: directory.path).isEmpty,
          "maintenance removes thumbnails for deleted or concealed history")

let limited = ThumbnailCache(directory: directory, maximumCount: 1)
limited.save(preview, id: 1, payload: fileOnly, isConcealed: false)
limited.save(preview, id: 2, payload: embedded, isConcealed: false)
try check(try manager.contentsOfDirectory(atPath: directory.path).count == 1, "cache count is bounded")
ThumbnailCache(directory: directory, maximumBytes: 1).prune { _ in true }
try check(try manager.contentsOfDirectory(atPath: directory.path).isEmpty, "cache bytes are bounded")
let invalidDirectory = root.appendingPathComponent("not-a-directory")
try Data().write(to: invalidDirectory)
try check(ThumbnailCache(directory: invalidDirectory).thumbnail(id: 2, payload: embedded, isConcealed: false) != nil,
          "cache write failure still displays embedded pixels")

let clip = ClipSummary(id: 1, date: Date(), kind: .file, title: "original.png", text: original.path,
                       source: "Fixture", byteCount: fileOnly.byteCount)
let card = ClipCardView(clip: clip, revealedText: nil, thumbnail: nil) { _ in }
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
try check(descendants(card).compactMap { $0 as? NSImageView }.contains { $0.image != nil },
          "file without a cached thumbnail has a visible placeholder icon")
print("PASS: \(count) thumbnail cache checks")
