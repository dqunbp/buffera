import AppKit
import BuferaCore

// Run from the repository root (the windows stay offscreen; no history or prefs):
// mkdir -p .build/history-cards-checks
// swiftc -emit-library -emit-module -module-name BuferaCore Sources/BuferaCore/Clip.swift -emit-module-path .build/history-cards-checks/BuferaCore.swiftmodule -o .build/history-cards-checks/libBuferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I .build/history-cards-checks -L .build/history-cards-checks -lBuferaCore -Xlinker -rpath -Xlinker "$PWD/.build/history-cards-checks" -module-cache-path .build/ModuleCache Sources/Bufera/ClipCardView.swift Sources/Bufera/HistoryCardsView.swift Tests/HistoryCardsChecks/main.swift -o .build/history-cards-checks/checks
// .build/history-cards-checks/checks

var checkCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
    checkCount += 1
    print("PASS", message)
}

func fixture(_ index: Int) -> ClipSummary {
    ClipSummary(id: Int64(index), date: Date(), kind: .text, title: "Fixture \(index)",
                text: "Fixture \(index)", source: "Checks", byteCount: 10)
}

func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

let one = HistoryCardsMetrics(viewport: NSSize(width: 444, height: 600), requestedColumns: 4, visibleRows: 6)
check(one.columns == 1 && one.itemSize.width == 444 && one.itemSize.height == 96, "narrow viewport falls back to one column")
let exact = HistoryCardsMetrics(viewport: NSSize(width: 944, height: 640), requestedColumns: 4, visibleRows: 3)
check(exact.columns == 4 && exact.itemSize.width == 230 && exact.itemSize.height == 208, "four columns at exact minimum and three tall rows")
let below = HistoryCardsMetrics(viewport: NSSize(width: 943, height: 300), requestedColumns: 4, visibleRows: 12)
check(below.columns == 3 && below.itemSize.height == 96, "column boundary and dense rows retain readable minimum")
check(HistoryCardsMetrics.selection(9, count: 4) == 3 && HistoryCardsMetrics.selection(0, count: 0) == -1, "selection clamps after removal and empty list")
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let grid = HistoryCardsView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
let window = NSWindow(contentRect: grid.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = grid
var clips = (0..<80).map(fixture)
var selections: [Int] = []
var actions: [Int64] = []
grid.columns = 4
grid.visibleRows = 6
grid.makeCard = { index in
    let clip = clips[index]
    return ClipCardView(clip: clip, revealedText: nil, thumbnail: nil) { _ in actions.append(clip.id) }
}
grid.onSelect = { selections.append($0) }
grid.layoutSubtreeIfNeeded()
grid.reload(count: clips.count, selectedIndex: 0, scrollToSelection: true)
grid.layoutSubtreeIfNeeded()
check(grid.effectiveColumns == 4, "actual collection uses four columns")
check(!grid.visibleIndices().isEmpty && grid.visibleIndices().count < clips.count, "collection presents only visible cards")
check(selections.isEmpty, "reload selection does not emit callback")
grid.select(2, scrollIntoView: true)
grid.select(2, scrollIntoView: true)
check(selections == [2], "selection callback fires once per changed index")
let original = grid.card(at: 2)!
clips.remove(at: 0)
grid.remove(at: 0, selectedIndex: 1)
check(grid.selectedIndex == 1 && grid.card(at: 1) === original, "single removal keeps surviving card and shifts selection")
grid.select(0, scrollIntoView: false)
original.onSelect?()
check(grid.selectedIndex == 1, "retained card callback resolves new index after removal")
let copyButton = descendants(of: original).compactMap { $0 as? NSButton }.first { $0.tag == ClipCardAction.copy.rawValue }!
copyButton.performClick(nil)
check(actions == [2], "retained card action still targets the original record after removal")
grid.select(50, scrollIntoView: true)
let origin = grid.scrollView.contentView.bounds.origin
let selectedCard = grid.card(at: 50)
clips += (80..<100).map(fixture)
grid.reload(count: clips.count, selectedIndex: 50, scrollToSelection: false)
check(abs(grid.scrollView.contentView.bounds.origin.y - origin.y) < 1, "pagination preserves scroll position")
check(grid.card(at: 50) === selectedCard, "pagination preserves existing card views")
window.setContentSize(NSSize(width: 444, height: 300))
grid.layoutSubtreeIfNeeded()
check(grid.effectiveColumns == 1, "resize reduces effective columns")

let longText = String(repeating: "Карточка использует место для длинного текста. ", count: 30)
let textClip = ClipSummary(id: 200, date: Date(), kind: .text, title: "Long text", text: longText, source: "Checks", byteCount: 100)
let textCard = ClipCardView(clip: textClip, revealedText: nil, thumbnail: nil) { _ in }
let previewHost = NSView(frame: NSRect(x: 0, y: 0, width: 444, height: 208))
textCard.frame = previewHost.bounds
textCard.autoresizingMask = [.width, .height]
previewHost.addSubview(textCard)
textCard.layoutSubtreeIfNeeded()
let textField = descendants(of: textCard).compactMap { $0 as? NSTextField }
    .first { $0.stringValue == longText.trimmingCharacters(in: .whitespacesAndNewlines) }!
check(textField.maximumNumberOfLines > 2 && textField.frame.height > 32,
      "tall text card displays additional preview lines")
previewHost.setFrameSize(NSSize(width: 230, height: 96))
textCard.layoutSubtreeIfNeeded()
check(textField.maximumNumberOfLines == 2, "compact card returns to a two-line preview")

let imageClip = ClipSummary(id: 201, date: Date(), kind: .image, title: "Картинка", text: "", source: "Checks", byteCount: 100)
let imageCard = ClipCardView(clip: imageClip, revealedText: nil, thumbnail: NSImage(size: NSSize(width: 96, height: 96))) { _ in }
textCard.removeFromSuperview()
imageCard.frame = previewHost.bounds
imageCard.autoresizingMask = [.width, .height]
previewHost.addSubview(imageCard)
imageCard.layoutSubtreeIfNeeded()
let imageView = descendants(of: imageCard).compactMap { $0 as? NSImageView }.first!
check(imageView.frame.height == 56, "compact image card retains its thumbnail size")
let imageButtons = descendants(of: imageCard).compactMap { $0 as? NSButton }
check(imageButtons.count == 5 && imageButtons.allSatisfy { button in
    !button.isHidden && imageCard.bounds.contains(button.convert(button.bounds, to: imageCard))
}, "all image actions fit in a compact 230 pt card")
previewHost.setFrameSize(NSSize(width: 444, height: 208))
imageCard.layoutSubtreeIfNeeded()
check(imageView.frame.height == 144, "tall image card expands its thumbnail")
check(imageButtons.count == 5 && imageButtons.allSatisfy { button in
    !button.isHidden && imageCard.bounds.contains(button.convert(button.bounds, to: imageCard))
}, "all image actions remain inside the card")
print("\(checkCount) history cards checks passed")
