import AppKit
import BufferaCore
import BufferaLocalization

var checks = 0
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "ClipDragChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    checks += 1
    print("PASS", message)
}
func rep(_ type: NSPasteboard.PasteboardType, _ value: String) -> Representation {
    .init(type: type.rawValue, data: Data(value.utf8))
}
func fixture(_ kind: ClipKind = .text, concealed: Bool = false) -> ClipSummary {
    .init(id: 1, date: Date(), kind: kind, title: "Private fixture", text: "Full fixture text",
          source: "Fixture", byteCount: 12, isConcealed: concealed)
}
func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

if CommandLine.arguments.contains("--interactive") || Bundle.main.bundleIdentifier?.hasPrefix("local.buffera.drag-qa") == true { runDragUI() }
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
NSApp.finishLaunching()
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("BufferaDragChecks-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: root) }
let exports = TemporaryImageExports(directory: root.appendingPathComponent("Images"))
let generalChange = NSPasteboard.general.changeCount
let longText = String(repeating: "Полное содержимое ", count: 20_000)
let custom = Representation(type: "app.example.custom-shape", data: Data([0, 255, 32, 0]))
let rich = NSAttributedString(string: "Bold text", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
let originals = ClipPayload(items: [
    [rep(.string, longText), rep(.html, "<b>Полное содержимое</b>"), custom],
    [.init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)],
    [rep(.string, "https://example.com/a?b=1")],
    [rep(.URL, "https://example.com/second")],
    [custom, rep(.init("org.nspasteboard.ConcealedType"), "")]
])
let prepared = try ClipDragPayload.prepare(originals, id: 1, exports: exports)
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
try check(board.writeObjects(prepared.pasteboardItems()), "native pasteboard accepts prepared drag items")
try check(board.pasteboardItems?.count == originals.items.count, "all object boundaries survive native pasteboard transport")
for (index, item) in originals.items.enumerated() {
    for representation in item {
        try check(board.pasteboardItems?[index].data(forType: .init(representation.type)) == representation.data,
                  "original representation survives byte-for-byte: \(representation.type)")
    }
}
try check(board.pasteboardItems?[0].string(forType: .string) == longText, "full text exceeds preview/index limits without truncation")
try check(board.pasteboardItems?[1].string(forType: .string) == "Bold text", "RTF retains formatting and gains plain text fallback")
try check(board.pasteboardItems?[2].string(forType: .URL) == "https://example.com/a?b=1", "text links gain native URL representation")
try check(board.pasteboardItems?[3].string(forType: .string) == "https://example.com/second", "URL-only items gain plain text fallback")

let folder = root.appendingPathComponent("folder", isDirectory: true)
try fm.createDirectory(at: folder, withIntermediateDirectories: false)
let file = root.appendingPathComponent("file with spaces.txt")
try Data("file body".utf8).write(to: file)
let files = ClipPayload(items: [[rep(.fileURL, file.absoluteString)], [rep(.fileURL, folder.absoluteString)]])
let fileDrag = try ClipDragPayload.prepare(files, id: 2, exports: exports)
try check(fileDrag.items == files.items, "multiple files and folders retain original URLs")
try check(fm.fileExists(atPath: file.path) && fm.fileExists(atPath: folder.path), "preparation never moves or removes originals")
try fm.removeItem(at: file)
do {
    _ = try ClipDragPayload.prepare(files, id: 2, exports: exports)
    fatalError("Missing file must fail the entire group")
} catch ClipDragFailure.fileUnavailable { checks += 1 }
for broken in [ClipPayload(items: []), ClipPayload(items: [[]]),
               ClipPayload(items: [[rep(.fileURL, "https://example.com/not-a-file")]])] {
    do { _ = try ClipDragPayload.prepare(broken, id: 3, exports: exports); fatalError("Invalid payload accepted") }
    catch is ClipDragFailure { checks += 1 }
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
memset(bitmap.bitmapData!, 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
let png = bitmap.representation(using: .png, properties: [:])!
let tiff = bitmap.tiffRepresentation!
let images = ClipPayload(items: [[.init(type: NSPasteboard.PasteboardType.png.rawValue, data: png)],
                                [.init(type: NSPasteboard.PasteboardType.tiff.rawValue, data: tiff)]])
let imageDrag = try ClipDragPayload.prepare(images, id: 4, exports: exports)
let imageItems = try imageDrag.pasteboardItems()
let imageURLs = imageItems.map { URL(string: $0.string(forType: .fileURL)!)! }
try check(Set(imageURLs).count == 2 && imageItems.count == 2, "each image gets its own file alternative, without duplicate drag objects")
try check(imageItems[0].data(forType: .png) == png && imageItems[1].data(forType: .tiff) == tiff,
          "image fallbacks do not replace original PNG and TIFF representations")
for url in imageURLs {
    try check(NSBitmapImageRep(data: Data(contentsOf: url))?.pixelsWide == 3, "exported file contains the full image")
    try check((try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              "drag image file has private permissions")
}
let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
let otherImage = try ClipDragPayload.prepare(.init(items: [[.init(type: "public.jpeg", data: jpeg)]]), id: 5, exports: exports)
try check(try otherImage.pasteboardItems()[0].string(forType: .fileURL)?.hasSuffix(".jpeg") == true,
          "image representations are exported even when record classification is other")
let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"3\" height=\"2\"></svg>".utf8)
let vector = try ClipDragPayload.prepare(.init(items: [[.init(type: "public.svg-image", data: svg)]]), id: 7, exports: exports)
let vectorURL = URL(string: try vector.pasteboardItems()[0].string(forType: .fileURL)!)!
try check(try Data(contentsOf: vectorURL) == svg, "vector image file fallback preserves content without requiring ImageIO rendering")
try exports.cleanup()
try check(imageURLs.allSatisfy { fm.fileExists(atPath: $0.path) }, "files survive completion for asynchronous receivers")
let small = TemporaryImageExports(directory: root.appendingPathComponent("Small"), maximumBytes: 8)
let batch = try small.files([.init(data: Data([1, 2, 3, 4]), fileExtension: "png", itemIndex: 0),
                            .init(data: Data([5, 6, 7, 8]), fileExtension: "png", itemIndex: 1)], id: 6)
try check(batch.allSatisfy { fm.fileExists(atPath: $0.path) }, "batch eviction protects every image in the current drag")
for url in batch { try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: url.path) }
try small.cleanup()
try check(batch.allSatisfy { !fm.fileExists(atPath: $0.path) }, "indexed image exports expire through the existing cache cleanup")
for kind in ClipKind.allCases {
    try check(ClipDragController.previewLabel(for: fixture(kind, concealed: true), count: 3) == L10n.text("Скрытая запись"),
              "concealed \(kind) preview hides content and item count")
}

// Exercise actual panel/card callbacks; use deferred preparation so no native
// drag starts in this noninteractive suite.
var fixtureFrontmostApp: NSRunningApplication?
let panel = HistoryPanel(monitorsOutsideInteractions: false, currentFrontmostApplication: { fixtureFrontmostApp })
panel.window.delegate = nil
panel.window.alphaValue = 0
panel.window.orderFront(nil)
panel.window.contentView?.layoutSubtreeIfNeeded()
panel.receive([fixture()], total: 1, offset: 0)
let cards = descendants(panel.window.contentView!).compactMap { $0 as? HistoryCardsView }.first!
var completions: [Int64] = []
var confirmations: [Int64] = []
var refreshes = 0
panel.onDragCompleted = { completions.append($0) }
panel.onConfirm = { confirmations.append($0) }
panel.request = { _, _, _ in refreshes += 1 }
panel.requestDragPayload = { _, _ in }
let card = cards.card(at: 0)!
card.requestDrag? { _ in }
panel.dismissForOutsideInteraction()
panel.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel.window))
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
try check(panel.window.isVisible && panel.isInteracting, "focus loss cannot close a drag source panel")
panel.clipboardDidCapture(id: 99)
try check(refreshes == 0 && panel.selected?.id == 1, "background capture cannot replace a source card during dragging")
let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                            windowNumber: panel.window.windowNumber, context: nil, characters: "\r",
                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
_ = panel.window.onKeyDown?(enter)
try check(confirmations.isEmpty, "Enter cannot copy to the general clipboard during drag preparation")
card.onDragFinished?([], nil)
try check(completions.isEmpty && refreshes == 1, "cancellation does not mark use and resumes deferred history refresh")
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(panel.window.isVisible, "cancelled drag keeps the unfocused panel visible")
panel.receive([fixture()], total: 1, offset: 0)
let nextCard = cards.card(at: 0)!
nextCard.requestDrag? { _ in }
panel.clipboardDidCapture(id: 100)
nextCard.onDragFinished?(.copy, nil)
nextCard.onDragFinished?(.copy, nil)
try check(completions == [1] && confirmations.isEmpty, "accepted copy marks use exactly once without clipboard confirmation")
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(panel.window.isVisible && refreshes == 2, "accepted drop keeps the unfocused panel visible and resumes deferred history refresh")
panel.dismissForOutsideInteraction()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(!panel.window.isVisible && confirmations.isEmpty, "outside click after drop closes an already unfocused panel without copying")

// Exercise the workspace activation handler, even if the panel
// has already lost key status during an earlier drop.
panel.window.orderFront(nil)
panel.receive([fixture()], total: 1, offset: 0)
let switchCard = cards.card(at: 0)!
switchCard.requestDrag? { _ in }
guard let otherApp = NSWorkspace.shared.runningApplications.first(where: {
    $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}) else { fatalError("No other running application for activation fixture") }
func switchApplication() {
    fixtureFrontmostApp = otherApp
    panel.applicationDidActivate(otherApp)
}
switchApplication()
try check(panel.window.isVisible, "application activation during drag cannot close the source")
switchCard.onDragFinished?(.copy, nil)
switchApplication()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(!panel.window.isVisible, "application switch after drop dismisses the unfocused panel")

panel.window.orderFront(nil)
panel.receive([fixture()], total: 1, offset: 0)
fixtureFrontmostApp = .current
panel.applicationDidActivate(otherApp)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(panel.window.isVisible, "a stale activation for an app that is no longer frontmost cannot dismiss")
switchApplication()
fixtureFrontmostApp = .current
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(panel.window.isVisible, "activation dismissal rechecks the frontmost app after deferral")
panel.showNearby(id: 1)
let pin = descendants(panel.window.contentView!).compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "history.pin" }!
pin.performClick(nil)
panel.dismissForOutsideInteraction()
switchApplication()
try check(panel.window.isVisible && panel.isShowingNearby, "pin protects nearby from outside clicks and application switching")
let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
    windowNumber: panel.window.windowNumber, context: nil, characters: "\u{1b}",
    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
_ = panel.window.onKeyDown?(escape)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(panel.window.isVisible && panel.isShowingNearby, "Escape preserves pinned nearby history")
panel.close(restoreFocus: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
panel.window.orderFront(nil)
panel.receive([fixture()], total: 1, offset: 0)
let preparingCard = cards.card(at: 0)!
let startDrag = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20),
    modifierFlags: [], timestamp: 0, windowNumber: panel.window.windowNumber, context: nil,
    eventNumber: 1, clickCount: 1, pressure: 1)!
let moveDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 40, y: 20),
    modifierFlags: [], timestamp: 0, windowNumber: panel.window.windowNumber, context: nil,
    eventNumber: 2, clickCount: 1, pressure: 1)!
preparingCard.mouseDown(with: startDrag)
preparingCard.mouseDragged(with: moveDrag)
try check(panel.window.onKeyDown?(escape) == true && panel.window.isVisible,
          "Escape consumes cancellation of pending drag preparation without closing the panel")
_ = panel.window.onKeyDown?(escape)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(panel.window.isVisible, "Escape after drag cancellation still respects pinning")
pin.performClick(nil)
_ = panel.window.onKeyDown?(escape)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
try check(!panel.window.isVisible, "unpinning allows dismissal after drag cancellation")
panel.window.orderOut(nil)

let source = NSView()
// Some pointing devices / automation supply a zero click count for a drag.
// Test the real card event entry point, including threshold and release.
let gestureCard = ClipCardView(clip: fixture(), revealedText: nil, thumbnail: nil) { _ in }
gestureCard.onSelect = {}
var gestureRequests = 0
var gestureFinishes = 0
gestureCard.requestDrag = { _ in gestureRequests += 1 }
gestureCard.onDragFinished = { _, _ in gestureFinishes += 1 }
func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 0) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 0), modifierFlags: [], timestamp: 0,
                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}
for clicks in [0, 1] {
    let previous = gestureRequests
    gestureCard.mouseDown(with: mouse(.leftMouseDown, x: 0, clicks: clicks))
    gestureCard.mouseDragged(with: mouse(.leftMouseDragged, x: 3))
    try check(gestureRequests == previous, "small mouse movement does not start drag")
    gestureCard.mouseDragged(with: mouse(.leftMouseDragged, x: 10))
    gestureCard.mouseDragged(with: mouse(.leftMouseDragged, x: 20))
    try check(gestureRequests == previous + 1, "drag starts once for click count \(clicks)")
    gestureCard.mouseUp(with: mouse(.leftMouseUp, x: 20))
}
try check(gestureFinishes == 2, "release cancels both pending card gestures")
gestureCard.mouseDown(with: mouse(.leftMouseDown, x: 0, clicks: 2))
gestureCard.mouseDragged(with: mouse(.leftMouseDragged, x: 20))
try check(gestureRequests == 2, "double click does not also start dragging")
gestureCard.setActionsEnabled(false)
gestureCard.mouseDown(with: mouse(.leftMouseDown, x: 0))
gestureCard.mouseDragged(with: mouse(.leftMouseDragged, x: 20))
try check(gestureRequests == 2, "disabled card cannot start dragging")
let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
var pending: ((Result<ClipDragPayload, Error>) -> Void)?
var finished = 0
let controller = ClipDragController(view: source, clip: fixture(), event: down) { operation, error in
    precondition(operation.isEmpty && error == nil); finished += 1
}
controller.prepare { pending = $0 }
controller.cancelPreparation(); controller.cancelPreparation()
pending?(.success(prepared))
try check(finished == 1 && !controller.isDragging, "cancelled preparation ignores late callbacks and completes only once")
try check(NSPasteboard.general.changeCount == generalChange, "all preparation, cancellation and completion paths leave the general clipboard unchanged")
print("\(checks) drag checks passed")
