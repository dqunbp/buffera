import AppKit
import BufferaCore

func recordingChecks() {
    let board = NSPasteboard(name: .init("Buffera.RecordingChecks.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let service = ClipboardService(pasteboard: board, frontmostApplicationName: { "Fixture" })
    var captures = 0
    service.onCapture = { _ in captures += 1 }
    func copy(_ text: String, temporary: Bool = false) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if temporary { item.setData(Data(), forType: .init("org.nspasteboard.TransientType")) }
        board.clearContents(); board.writeObjects([item])
    }
    service.toggleSkipNextCopy()
    board.clearContents(); service.poll()
    check(service.skipsNextCopy, "Clearing the clipboard does not consume skip")
    copy("service data", temporary: true); service.poll()
    check(service.skipsNextCopy, "Transient writes do not consume skip")
    copy("secret"); service.poll()
    check(!service.skipsNextCopy && captures == 0, "Next copy is skipped and recording resumes")
    service.poll()
    check(captures == 0, "Skipped copy cannot be captured by a later poll")
    copy("ordinary"); service.poll()
    check(captures == 1, "Copy after skipped copy is recorded")
    service.toggleSkipNextCopy()
    copy("pending secret")
    service.toggleSkipNextCopy(); service.poll()
    check(!service.skipsNextCopy && captures == 1, "Cancelling discards pending protected copy")
    service.paused = true
    service.toggleSkipNextCopy()
    check(!service.skipsNextCopy, "Skip is unavailable while paused")
    copy("paused secret")
    service.paused = false; service.poll()
    check(captures == 1, "Resume discards unpolled changes from pause")
    service.toggleSkipNextCopy()
    service.paused = true; service.paused = false
    check(!service.skipsNextCopy, "Entering pause cancels pending one-shot")
    service.toggleSkipNextCopy()
    var allowed = false
    service.captureIsAllowed = { allowed }
    copy("locked"); service.poll()
    allowed = true; service.poll()
    check(service.skipsNextCopy && captures == 1, "Session transitions preserve skip and discard blocked content")
    let first = NSPasteboardItem(); first.setString("one", forType: .string)
    let second = NSPasteboardItem(); second.setString("two", forType: .string)
    board.clearContents(); board.writeObjects([first, second]); service.poll()
    check(!service.skipsNextCopy && captures == 1, "One skip covers the entire multi-item group")
    service.toggleSkipNextCopy()
    let payload = ClipPayload(items: [[Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("history".utf8))]])
    try! service.restore(payload)
    service.poll()
    check(service.skipsNextCopy && captures == 1, "Restoring history does not consume a pending skip")
    let provider = RecordingPromise()
    let promised = NSPasteboardItem()
    promised.setDataProvider(provider, forTypes: [.string])
    board.clearContents(); board.writeObjects([promised]); service.poll()
    check(provider.reads == 0 && !service.skipsNextCopy && captures == 1, "Skip does not request promised content")
    copy("after group"); service.poll()
    check(captures == 2, "Recording resumes after multi-item skip")
}

private final class RecordingPromise: NSObject, NSPasteboardItemDataProvider {
    var reads = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        reads += 1
        item.setString("secret", forType: type)
    }
}
