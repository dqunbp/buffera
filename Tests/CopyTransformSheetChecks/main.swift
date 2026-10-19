import AppKit
import BufferaCore

// No clipboard, database, or app activation is used. The fixture windows are transparent.
// mkdir -p .build/copy-transform-sheet-checks
// swiftc -emit-library -emit-module -module-name BufferaCore Sources/BufferaCore/Clip.swift Sources/BufferaCore/TextTransformation.swift -emit-module-path .build/copy-transform-sheet-checks/BufferaCore.swiftmodule -o .build/copy-transform-sheet-checks/libBufferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I .build/copy-transform-sheet-checks -L .build/copy-transform-sheet-checks -lBufferaCore -Xlinker -rpath -Xlinker "$PWD/.build/copy-transform-sheet-checks" -module-cache-path .build/ModuleCache Sources/Buffera/CopyTransformOperation.swift Sources/Buffera/CopyTransformSheet.swift Tests/CopyTransformSheetChecks/main.swift -o .build/copy-transform-sheet-checks/checks
// .build/copy-transform-sheet-checks/checks

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checkCount += 1
    print("PASS", message)
}

func descendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants($0) }
}

func waitUntil(_ description: String, _ condition: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !condition(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    check(condition(), description)
}

func fixture(_ kind: ClipKind = .text, concealed: Bool = false) -> ClipSummary {
    ClipSummary(id: 1, date: Date(), kind: kind, title: "Fixture", text: "", source: "Checks", byteCount: 4,
                isConcealed: concealed)
}

let error = NSError(domain: "CopyTransformSheetChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Проверочная ошибка"])

final class Harness {
    let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let sheet = CopyTransformSheet()
    var requests: [(operation: CopyTransformOperation, complete: (Result<String, Error>) -> Void)] = []
    var copies: [(text: String, complete: (Error?) -> Void)] = []
    var closures: [Bool] = []
    var detachedAtClose = true

    init() {
        parent.isReleasedWhenClosed = false
        parent.alphaValue = 0
        parent.orderFront(nil)
        sheet.onRequest = { [weak self] in self?.requests.append(($0, $1)) }
        sheet.onCopy = { [weak self] in self?.copies.append(($0, $1)) }
        sheet.onClose = { [weak self] copied in
            guard let self else { return }
            self.detachedAtClose = self.detachedAtClose && self.parent.attachedSheet == nil
            self.closures.append(copied)
        }
    }

    func show(_ clip: ClipSummary = fixture()) {
        sheet.show(for: clip, relativeTo: parent)
        if sheet.isShown {
            waitUntil("Sheet attaches to the history window") { self.parent.attachedSheet != nil }
        }
        parent.attachedSheet?.alphaValue = 0
        parent.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
    }

    var window: NSWindow { parent.attachedSheet! }
    var views: [NSView] { descendants(window.contentView!) }
    var selector: NSPopUpButton { views.compactMap { $0 as? NSPopUpButton }.first! }
    var preview: NSTextView { views.compactMap { $0 as? NSTextView }.first! }
    var copy: NSButton { views.compactMap { $0 as? NSButton }.first { $0.title == "В буфер" }! }
    var status: NSTextField {
        views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Состояние преобразования" }!
    }
    func select(_ index: Int) {
        selector.selectItem(at: index)
        selector.sendAction(selector.action, to: selector.target)
    }
    func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        check(window.performKeyEquivalent(with: event), "Sheet handles its keyboard command")
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
NSApp.finishLaunching()
let h = Harness()
h.show()
check(h.sheet.isShown && h.selector.numberOfItems == 5 && h.requests.first!.operation == .text(.plainText),
      "Text sheet offers the five operations and initially requests plain text")
check(!h.copy.isEnabled && h.preview.string.isEmpty && !h.preview.isEditable && h.preview.isSelectable,
      "Loading has no copyable result and the preview is read-only but selectable")
check(h.window.contentView!.bounds.width >= 480 && !h.window.contentView!.hasAmbiguousLayout,
      "A narrow history parent still provides a readable sheet layout")
h.key(36, "\r")
check(h.copies.isEmpty, "Return does not copy while the transformation is pending")
h.select(1)
h.requests[0].complete(.success("stale value"))
h.requests[0].complete(.failure(error))
check(h.preview.string.isEmpty && !h.copy.isEnabled, "Old success and failure callbacks cannot replace a newer operation")
let exact = "  {\n\t\"word\": \"Привет\"\n}  \n"
h.requests[1].complete(.success(exact))
check(h.preview.string == exact && h.copy.isEnabled, "The preview preserves whitespace and Unicode exactly")
h.requests[1].complete(.failure(error))
check(h.preview.string == exact && h.copy.isEnabled, "A duplicate completion cannot erase a successful result")
h.copy.performClick(nil)
check(h.copies.count == 1 && h.copies[0].text == exact && !h.copy.isEnabled && !h.selector.isEnabled,
      "Copy sends the exact result once and locks the operation while writing")
h.key(36, "\r")
check(h.copies.count == 1, "Repeated Return cannot submit a second pending copy")
h.copies[0].complete(error)
check(h.sheet.isShown && h.copy.isEnabled && h.preview.string == exact && h.status.stringValue == error.localizedDescription,
      "A copy error keeps the exact preview available for retry")
h.copy.performClick(nil)
h.copies[0].complete(nil)
check(h.sheet.isShown, "A late completion from the failed copy cannot close its retry")
h.copies[1].complete(nil)
h.copies[1].complete(nil)
check(!h.sheet.isShown && h.closures == [true] && h.detachedAtClose,
      "Successful copy detaches the sheet before closing exactly once")

h.show()
let cancelledRequest = h.requests.last!.complete
let discardedPreview = h.preview
h.key(53, "\u{1b}")
check(!h.sheet.isShown && h.closures == [true, false] && discardedPreview.string.isEmpty,
      "Escape closes synchronously and releases the preview")
cancelledRequest(.success("late secret"))
cancelledRequest(.failure(error))
check(discardedPreview.string.isEmpty && h.closures.count == 2,
      "Cancelled transformation callbacks cannot restore text or notify close again")

h.show()
cancelledRequest(.success("previous presentation"))
check(h.preview.string.isEmpty && !h.copy.isEnabled, "A previous presentation cannot affect a reopened sheet")
h.requests.last!.complete(.success("new copy"))
h.copy.performClick(nil)
let cancelledCopy = h.copies.last!.complete
h.sheet.close()
check(!h.sheet.isShown && h.closures.last == false && h.detachedAtClose,
      "Closing during a pending write synchronously detaches and cancels")
cancelledCopy(nil)
cancelledCopy(error)
check(h.closures.count == 3, "Late copy callbacks after cancellation are ignored")

h.show()
h.requests.last!.complete(.failure(error))
check(h.preview.string.isEmpty && !h.copy.isEnabled && h.status.stringValue == error.localizedDescription,
      "A transformation error has no copyable result and explains the failure")
h.select(2)
h.requests.last!.complete(.success(""))
check(h.preview.string.isEmpty && !h.copy.isEnabled && h.status.stringValue.contains("пуст"),
      "An empty transformation is explained and cannot be copied")
h.select(0)
let large = String(repeating: "Я", count: 500_001) + "\nEND"
h.requests.last!.complete(.success(large))
check(h.preview.string == String(large.prefix(500_000)) && h.status.stringValue.contains("весь текст"),
      "Large results display an explicit bounded preview without modifying its content")
h.copy.performClick(nil)
check(h.copies.last!.text == large, "Copy retains the full result beyond the preview limit")
h.sheet.close()

h.show(fixture(.image))
check(h.selector.numberOfItems == 1 && !h.selector.isEnabled && h.requests.last!.operation == .imageText,
      "An image offers only OCR with its explanatory detail")
h.requests.last!.complete(.success("Recognized text"))
h.key(13, "w", modifiers: .command)
check(!h.sheet.isShown && h.closures.last == false, "Command-W cancels the sheet")
h.show(fixture(.text, concealed: true))
check(!h.sheet.isShown && h.parent.attachedSheet == nil, "Concealed content cannot open a transformation sheet")
h.show(fixture(.file))
check(!h.sheet.isShown && h.parent.attachedSheet == nil, "Unsupported clip types cannot open a transformation sheet")

h.show()
let externallyEnded = h.window
h.parent.endSheet(externallyEnded, returnCode: .cancel)
waitUntil("An externally ended sheet clears its active state") { !h.sheet.isShown }
check(h.detachedAtClose, "Every close callback observes a detached sheet")
h.parent.orderOut(nil)
print("PASS: \(checkCount) copy transformation sheet checks")
