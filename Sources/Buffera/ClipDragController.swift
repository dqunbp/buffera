import AppKit
import BufferaCore
import BufferaLocalization

/// One gesture owns its source view until AppKit finishes. Async preparation
/// cannot turn a mouse release or Escape into a late, unsolicited drag.
final class ClipDragController: NSObject, NSDraggingSource {
    typealias Preparation = (@escaping (Result<ClipDragPayload, Error>) -> Void) -> Void
    private let view: NSView
    private let clip: ClipSummary
    private let event: NSEvent
    private var finish: ((NSDragOperation, Error?) -> Void)?
    private(set) var isDragging = false
    private var completed = false

    init(view: NSView, clip: ClipSummary, event: NSEvent,
         finish: @escaping (NSDragOperation, Error?) -> Void) {
        self.view = view; self.clip = clip; self.event = event; self.finish = finish
    }

    func prepare(using request: Preparation) {
        request { [weak self] result in
            guard let self, !self.completed, !self.isDragging else { return }
            guard self.view.window?.isVisible == true, NSEvent.pressedMouseButtons & 1 != 0 else {
                self.complete(operation: [], error: nil); return
            }
            do {
                let items = try result.get().pasteboardItems()
                guard !items.isEmpty else { throw ClipDragFailure.unreadable }
                let image = Self.preview(for: self.clip, count: items.count)
                let point = self.view.convert(self.event.locationInWindow, from: nil)
                let draggingItems = items.enumerated().map { index, item in
                    let dragging = NSDraggingItem(pasteboardWriter: item)
                    let offset = CGFloat(min(index, 3)) * 4
                    dragging.setDraggingFrame(NSRect(x: point.x + offset, y: point.y - image.size.height + offset,
                                                     width: image.size.width, height: image.size.height), contents: image)
                    return dragging
                }
                self.isDragging = true
                let session = self.view.beginDraggingSession(with: draggingItems, event: self.event, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = true
                session.draggingFormation = .pile
            } catch { self.complete(operation: [], error: error) }
        }
    }

    func cancelPreparation() {
        guard !isDragging else { return }
        complete(operation: [], error: nil)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        complete(operation: operation.intersection(.copy), error: nil)
    }

    private func complete(operation: NSDragOperation, error: Error?) {
        guard !completed else { return }
        completed = true
        let callback = finish; finish = nil
        callback?(operation, error)
    }

    static func previewLabel(for clip: ClipSummary, count: Int) -> String {
        if clip.isConcealed { return L10n.text("Скрытая запись") }
        return count > 1 ? L10n.text("Объектов: \(count)") : clip.kind.label
    }

    /// No card snapshot: even an explicitly revealed secret stays out of the
    /// drag image, as do filenames, thumbnails, and custom application data.
    static func preview(for clip: ClipSummary, count: Int) -> NSImage {
        let label = previewLabel(for: clip, count: count)
        return NSImage(size: NSSize(width: 180, height: 44), flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            let symbol = clip.isConcealed ? "lock.fill" : clip.kind.symbol
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .draw(in: NSRect(x: 12, y: 12, width: 20, height: 20))
            (label as NSString).draw(in: NSRect(x: 42, y: 12, width: 130, height: 20),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            return true
        }
    }
}
