import AppKit
import BufferaCore

// Run from the repository root (the windows stay offscreen; no history or prefs):
// mkdir -p .build/history-cards-checks
// swiftc -emit-library -emit-module -module-name BufferaCore Sources/BufferaCore/Clip.swift Sources/BufferaCore/TextTransformation.swift -emit-module-path .build/history-cards-checks/BufferaCore.swiftmodule -o .build/history-cards-checks/libBufferaCore.dylib -module-cache-path .build/ModuleCache
// swiftc -I .build/history-cards-checks -L .build/history-cards-checks -lBufferaCore -Xlinker -rpath -Xlinker "$PWD/.build/history-cards-checks" -module-cache-path .build/ModuleCache Sources/Buffera/CopyTransformOperation.swift Sources/Buffera/CopyTransformMenu.swift Sources/Buffera/ClipCardView.swift Sources/Buffera/HistoryCardsView.swift Tests/HistoryCardsChecks/main.swift -o .build/history-cards-checks/checks
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

let menuEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                   timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
var transformRequests = 0
var chosenTransforms: [CopyTransformOperation] = []
var transformCardActions: [ClipCardAction] = []
let transformCard = ClipCardView(clip: fixture(900), revealedText: nil, thumbnail: nil) {
    transformCardActions.append($0)
}
transformCard.onRequestCopyTransformOperations = { transformRequests += 1 }
transformCard.onCopyTransform = { chosenTransforms.append($0) }
let contextMenu = transformCard.menu(for: menuEvent)!
let transformItem = contextMenu.item(withTag: ClipCardAction.copyDifferently.rawValue)!
let transformMenu = transformItem.submenu!
check(transformItem.title == "Скопировать иначе" && transformItem.submenu is CopyTransformMenu,
      "copy differently is a native submenu with no intermediate window action")
check(transformRequests == 1 && transformMenu.items.count == 1
      && transformMenu.items[0].title == "Проверяем варианты…" && !transformMenu.items[0].isEnabled,
      "unknown applicability requests content and shows only a disabled loading item")
transformCard.setCopyTransformOperations([.text(.plainText), .text(.formatJSON)])
check(transformItem.submenu === transformMenu && transformMenu.items.map(\.title) == ["Без форматирования", "Форматировать JSON"],
      "prepared operations update the existing submenu in place")
transformMenu.performActionForItem(at: 1)
check(chosenTransforms == [.text(.formatJSON)] && transformCardActions.isEmpty,
      "choosing an operation dispatches it directly without invoking the sheet action")
let staleItem = transformMenu.items[1]
transformCard.setCopyTransformOperations([.text(.plainText)])
NSApp.sendAction(staleItem.action!, to: staleItem.target, from: staleItem)
check(chosenTransforms == [.text(.formatJSON)], "removed operation items cannot invoke a stale transformation")
transformCard.setActionsEnabled(false)
transformMenu.performActionForItem(at: 0)
check(!transformMenu.items[0].isEnabled && chosenTransforms.count == 1 && transformCard.menu(for: menuEvent) == nil,
      "pending card actions also disable an already-created transformation menu")
transformCard.setActionsEnabled(true)
transformMenu.performActionForItem(at: 0)
check(chosenTransforms == [.text(.formatJSON), .text(.plainText)], "reenabling the card restores direct transformation actions")
let transformButton = descendants(of: transformCard).compactMap { $0 as? NSButton }
    .first { $0.tag == ClipCardAction.copyDifferently.rawValue }!
transformButton.performClick(nil)
check(transformCardActions == [.copyDifferently], "footer uses the panel action so the shared popup lifecycle is preserved")
transformCard.setCopyTransformOperations([])
check(transformButton.isHidden && transformCard.menu(for: menuEvent)?.item(withTag: ClipCardAction.copyDifferently.rawValue) == nil,
      "records without applicable operations omit the submenu and footer button")
check(transformMenu.items.count == 1 && !transformMenu.items[0].isEnabled
      && transformMenu.items[0].title == "Нет подходящих вариантов",
      "an already-created menu becomes noninteractive when no operation remains")
transformCard.setCopyTransformOperations(nil)
check(!transformButton.isHidden, "invalidating applicability restores the pending button")
let privateClip = ClipSummary(id: 901, date: Date(), kind: .text, title: "Private", text: "Private",
                              source: "Checks", byteCount: 7, isConcealed: true)
let privateCard = ClipCardView(clip: privateClip, revealedText: "Private", thumbnail: nil) { _ in }
privateCard.setCopyTransformOperations([.text(.plainText)])
check(privateCard.menu(for: menuEvent)?.item(withTag: ClipCardAction.copyDifferently.rawValue) == nil,
      "a concealed record never offers transformations even if operations were supplied")

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
let gridSelectionEvents = selections.count
grid.scrollToSelection(centered: true)
let gridCollection = grid.scrollView.documentView as! NSCollectionView
let centeredGridFrame = gridCollection.layoutAttributesForItem(at: IndexPath(item: 50, section: 0))!.frame
check(abs(centeredGridFrame.midY - grid.scrollView.contentView.bounds.midY) < 1
      && grid.visibleIndices().contains(46) && grid.visibleIndices().contains(54),
      "centering in a four-column grid keeps neighboring rows visible above and below")
check(grid.selectedIndex == 50 && selections.count == gridSelectionEvents,
      "centering scrolls without changing selection or emitting a selection callback")
let origin = grid.scrollView.contentView.bounds.origin
let selectedCard = grid.card(at: 50)
clips += (80..<100).map(fixture)
grid.reload(count: clips.count, selectedIndex: 50, scrollToSelection: false)
check(abs(grid.scrollView.contentView.bounds.origin.y - origin.y) < 1, "pagination preserves scroll position")
check(grid.card(at: 50) === selectedCard, "pagination preserves existing card views")
let selectedID = clips[grid.selectedIndex].id
let replacementOrigin = grid.scrollView.contentView.bounds.origin
let selectionEvents = selections.count
clips.insert(contentsOf: [fixture(1_000), fixture(1_001)], at: 0)
let replacementSelection = clips.firstIndex { $0.id == selectedID }!
grid.replace(count: clips.count, selectedIndex: replacementSelection)
check(abs(grid.scrollView.contentView.bounds.origin.y - replacementOrigin.y) < 1,
      "search replacement preserves viewport when matches are inserted at the front")
check(clips[grid.selectedIndex].id == selectedID, "search replacement retains the selected record")
check(selections.count == selectionEvents, "search replacement does not emit a user selection callback")
let visibleReplacement = grid.visibleIndices().first!
let replacementCard = grid.card(at: visibleReplacement)!
check(descendants(of: replacementCard).compactMap { $0 as? NSTextField }
    .contains { $0.stringValue == clips[visibleReplacement].text },
      "larger search result replaces visible records instead of appending stale cards")
grid.select(0, scrollIntoView: false)
grid.scrollToSelection(centered: true)
check(grid.scrollView.contentView.bounds.origin.y == 0 && grid.visibleIndices().contains(0),
      "centering the first card clamps to the start of the list")
grid.select(clips.count - 1, scrollIntoView: false)
grid.scrollToSelection(centered: true)
let gridMaximumY = max(0, gridCollection.bounds.height - grid.scrollView.contentView.bounds.height)
check(abs(grid.scrollView.contentView.bounds.origin.y - gridMaximumY) < 1
      && grid.visibleIndices().contains(clips.count - 1),
      "centering the last card clamps to the end of the list")
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
check(imageView.frame.width == 226 && imageView.frame.height == 54,
      "compact image fills the preview area without a reserved label column")
check(!descendants(of: imageCard).compactMap { $0 as? NSTextField }.contains { $0.stringValue == imageClip.displayTitle },
      "image cards omit the redundant visible type label")
let imageButtons = descendants(of: imageCard).compactMap { $0 as? NSButton }
check(imageButtons.count == 7 && imageButtons.allSatisfy { button in
    !button.isHidden && imageCard.bounds.contains(button.convert(button.bounds, to: imageCard))
}, "all image actions fit in a compact 230 pt card")
previewHost.setFrameSize(NSSize(width: 444, height: 208))
imageCard.layoutSubtreeIfNeeded()
check(imageView.frame.width == 440 && imageView.frame.height == 166,
      "tall image card uses the full area beyond the old thumbnail limit")
check(imageView.imageScaling == .scaleProportionallyUpOrDown,
      "wide and portrait images preserve their proportions without cropping")
imageCard.setQuickShortcut(1)
imageCard.layoutSubtreeIfNeeded()
let imageBadge = descendants(of: imageCard).compactMap { $0 as? NSTextField }.first { $0.stringValue == "⌘1" }!
check(imageView.frame.contains(imageBadge.frame) && imageView.frame.width == 440,
      "quick-selection hint overlays the image without shrinking it")
imageCard.setQuickShortcut(nil)
check(imageButtons.count == 7 && imageButtons.allSatisfy { button in
    !button.isHidden && imageCard.bounds.contains(button.convert(button.bounds, to: imageCard))
}, "all image actions remain inside the card")

let shortClip = ClipSummary(id: 300, date: Date(), kind: .text, title: "OK", text: "OK", source: "Checks", byteCount: 2)
let photoFile = ClipSummary(id: 400, date: Date(), kind: .file, title: "Photo.jpeg", text: "/tmp/Photo.jpeg",
                            source: "Photos", byteCount: 100)
let photoFileCard = ClipCardView(clip: photoFile, revealedText: nil, thumbnail: nil) { _ in }
photoFileCard.frame = NSRect(x: 0, y: 0, width: 444, height: 208)
photoFileCard.layoutSubtreeIfNeeded()
let filename = descendants(of: photoFileCard).compactMap { $0 as? NSTextField }
    .first { $0.stringValue == photoFile.title }!
check(!filename.isHidden, "an image file retains its filename until a thumbnail is available")
let photoThumbnail = NSImage(size: NSSize(width: 300, height: 200))
photoFileCard.setThumbnail(photoThumbnail)
let photoView = descendants(of: photoFileCard).compactMap { $0 as? NSImageView }
    .first { $0.image === photoThumbnail }!
check(filename.isHidden && photoView.frame.width == 440 && photoView.frame.height == 166,
      "a Photos file displays its thumbnail across the full card preview area")
check(ClipCardView.preferredHeight(for: photoFile, revealedText: nil, width: 444, maximumHeight: 208) == 208,
      "image files receive the same preview height as image records")
check(!ClipCardAction.save.isAvailable(for: photoFile) && !ClipCardAction.finder.isAvailable(for: photoFile),
      "an image preview preserves file actions and does not reclassify the record")
for (path, concealed, expected) in [("/tmp/Photo.HEIC", false, true), ("/tmp/Notes.txt", false, false),
                                   ("/tmp/a.jpeg\n/tmp/b.jpeg", false, false), ("/tmp/Photo.jpeg", true, false)] {
    let candidate = ClipSummary(id: 401, date: Date(), kind: .file, title: "Fixture", text: path,
                                source: "Photos", byteCount: 100, isConcealed: concealed)
    check(ClipboardService.canPreviewImage(candidate) == expected,
          "preview eligibility respects image formats, file selections and concealed records: \(path), concealed=\(concealed)")
    if concealed {
        let card = ClipCardView(clip: candidate, revealedText: nil, thumbnail: photoThumbnail) { _ in }
        check(!descendants(of: card).compactMap { $0 as? NSImageView }.contains { $0.image === photoThumbnail },
              "a concealed image file never displays a supplied thumbnail")
    }
}
let wrappingText = "A medium length clipboard entry should use the available width and wrap only when the column needs additional lines."
let wrappingClip = ClipSummary(id: 301, date: Date(), kind: .text, title: "Wrapping", text: wrappingText, source: "Checks", byteCount: wrappingText.utf8.count)
let concealedClip = ClipSummary(id: 302, date: Date(), kind: .text, title: longText, text: longText,
                                source: "Checks", byteCount: 100_000, isConcealed: true)
let preferredShort = ClipCardView.preferredHeight(for: shortClip, revealedText: nil, width: 444, maximumHeight: 208)
let preferredWrapping = ClipCardView.preferredHeight(for: wrappingClip, revealedText: nil, width: 444, maximumHeight: 208)
let preferredNarrow = ClipCardView.preferredHeight(for: wrappingClip, revealedText: nil, width: 230, maximumHeight: 208)
let preferredLong = ClipCardView.preferredHeight(for: textClip, revealedText: nil, width: 444, maximumHeight: 208)
check(preferredShort == 74 && preferredShort < 208 / 2,
      "one-word panel card uses its content height instead of the tall row allocation")
check(preferredWrapping > preferredShort && preferredWrapping < 208,
      "wrapped panel text grows beyond one line without filling the maximum height")
check(preferredNarrow > preferredWrapping && preferredNarrow <= 208,
      "narrowing a panel card allocates more lines for the same text")
check(preferredLong == 208, "long panel text stops at the configured maximum height")
check(ClipCardView.preferredHeight(for: textClip, revealedText: nil, width: 444, maximumHeight: 500) == 242,
      "a tall panel does not reserve empty space beyond the twelve visible preview lines")
check(ClipCardView.preferredHeight(for: concealedClip, revealedText: nil, width: 444, maximumHeight: 208) == preferredShort,
      "concealed payload length does not affect the masked card height")
check(ClipCardView.preferredHeight(for: concealedClip, revealedText: longText, width: 444, maximumHeight: 208) == preferredLong,
      "explicitly revealed text participates in content sizing")

imageCard.removeFromSuperview()
let shortCard = ClipCardView(clip: shortClip, revealedText: nil, thumbnail: nil) { _ in }
previewHost.setFrameSize(NSSize(width: 230, height: preferredShort))
shortCard.frame = previewHost.bounds
shortCard.autoresizingMask = [.width, .height]
previewHost.addSubview(shortCard)
shortCard.layoutSubtreeIfNeeded()
let shortTextField = descendants(of: shortCard).compactMap { $0 as? NSTextField }.first { $0.stringValue == "OK" }!
check(shortTextField.maximumNumberOfLines == 1 && shortCard.bounds.contains(shortTextField.convert(shortTextField.bounds, to: shortCard)),
      "the 74 pt card renders its one-line preview inside its bounds")
check(descendants(of: shortCard).compactMap { $0 as? NSButton }.allSatisfy {
    !$0.isHidden && shortCard.bounds.contains($0.convert($0.bounds, to: shortCard))
}, "short panel card retains every action inside its bounds")
shortCard.removeFromSuperview()
let multilineText = "First line\nSecond line\nThird line"
let multilineClip = ClipSummary(id: 303, date: Date(), kind: .text, title: "Three lines", text: multilineText, source: "Checks", byteCount: multilineText.utf8.count)
let multilineHeight = ClipCardView.preferredHeight(for: multilineClip, revealedText: nil, width: 444, maximumHeight: 208)
let multilineCard = ClipCardView(clip: multilineClip, revealedText: nil, thumbnail: nil) { _ in }
previewHost.setFrameSize(NSSize(width: 444, height: multilineHeight))
multilineCard.frame = previewHost.bounds
previewHost.addSubview(multilineCard)
multilineCard.layoutSubtreeIfNeeded()
let multilineField = descendants(of: multilineCard).compactMap { $0 as? NSTextField }.first { $0.stringValue == multilineText }!
check(multilineHeight > preferredShort && multilineHeight < 208 && multilineField.maximumNumberOfLines >= 3 && multilineField.frame.height > 32,
      "content measurement and rendering retain all three explicit text lines")
multilineCard.removeFromSuperview()
let preferredImage = ClipCardView.preferredHeight(for: imageClip, revealedText: nil, width: 230, maximumHeight: 208)
check(preferredImage >= 106 && preferredImage <= 208, "panel image reserves enough height for its thumbnail and footer")
previewHost.setFrameSize(NSSize(width: 230, height: preferredImage))
imageCard.frame = previewHost.bounds
previewHost.addSubview(imageCard)
imageCard.layoutSubtreeIfNeeded()
check(imageView.frame.height >= 56 && imageCard.bounds.contains(imageView.convert(imageView.bounds, to: imageCard)) && imageButtons.allSatisfy {
    !$0.isHidden && imageCard.bounds.contains($0.convert($0.bounds, to: imageCard))
}, "thumbnail and all image actions fit at the content-sized panel height")

let contentGrid = HistoryCardsView(frame: NSRect(x: 0, y: 0, width: 444, height: 640))
let contentWindow = NSWindow(contentRect: contentGrid.frame, styleMask: [.borderless], backing: .buffered, defer: false)
contentWindow.contentView = contentGrid
let contentFixtures = [shortClip, textClip, imageClip, concealedClip, wrappingClip, shortClip]
var contentClips = (0..<48).map { index -> ClipSummary in
    let sample = contentFixtures[index % contentFixtures.count]
    return ClipSummary(id: Int64(2_000 + index), date: sample.date, kind: sample.kind, title: sample.title,
                       text: sample.text, source: sample.source, byteCount: sample.byteCount, isConcealed: sample.isConcealed)
}
var contentSelections: [Int] = []
var measuredIndices = Set<Int>()
contentGrid.visibleRows = 3
contentGrid.sizesToContent = true
contentGrid.heightForCard = { index, width, maximum in
    measuredIndices.insert(index)
    return ClipCardView.preferredHeight(for: contentClips[index], revealedText: nil, width: width, maximumHeight: maximum)
}
contentGrid.makeCard = { ClipCardView(clip: contentClips[$0], revealedText: nil, thumbnail: nil) { _ in } }
contentGrid.onSelect = { contentSelections.append($0) }
contentGrid.layoutSubtreeIfNeeded()
contentGrid.reload(count: contentClips.count, selectedIndex: 0, scrollToSelection: true)
contentGrid.layoutSubtreeIfNeeded()
let collection = contentGrid.scrollView.documentView as! NSCollectionView
func itemFrame(_ index: Int) -> NSRect {
    collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame
}
check(contentGrid.effectiveColumns == 1 && itemFrame(0).height == 74 && itemFrame(1).height == 208,
      "content-sized collection lays out short and long records with different heights")
check((0..<contentClips.count).allSatisfy { index in
    let frame = itemFrame(index)
    let preferred = ClipCardView.preferredHeight(for: contentClips[index], revealedText: nil, width: frame.width, maximumHeight: 208)
    return abs(frame.height - preferred) < 1
} && measuredIndices.count == contentClips.count,
      "every content-sized collection item receives its measured height")
check((1..<contentClips.count).allSatisfy { abs(itemFrame($0).minY - itemFrame($0 - 1).maxY - HistoryCardsMetrics.gap) < 1 },
      "heterogeneous panel cards retain the normal gap without empty row space")

contentGrid.select(20, scrollIntoView: true)
let contentCenterSelectionEvents = contentSelections.count
contentGrid.scrollToSelection(centered: true)
check(abs(itemFrame(20).midY - contentGrid.scrollView.contentView.bounds.midY) < 1
      && contentGrid.visibleIndices().contains(19) && contentGrid.visibleIndices().contains(21),
      "content-sized cards center by their actual frame with visible neighbors on both sides")
check(contentGrid.selectedIndex == 20 && contentSelections.count == contentCenterSelectionEvents,
      "centering a content-sized card preserves selection without callbacks")
let contentOrigin = contentGrid.scrollView.contentView.bounds.origin
let contentSelectedCard = contentGrid.card(at: 20)
let contentSelectionEvents = contentSelections.count
contentClips += (48..<60).map(fixture)
contentGrid.reload(count: contentClips.count, selectedIndex: 20, scrollToSelection: false)
contentGrid.layoutSubtreeIfNeeded()
check(contentSelectedCard != nil && contentGrid.card(at: 20) === contentSelectedCard,
      "content-sized pagination preserves the selected card instance")
check(abs(contentGrid.scrollView.contentView.bounds.origin.y - contentOrigin.y) < 1 && contentGrid.selectedIndex == 20 && contentSelections.count == contentSelectionEvents,
      "content-sized pagination preserves viewport and selection without callbacks")

contentWindow.setContentSize(NSSize(width: 484, height: 640))
contentGrid.columns = 2
contentGrid.layoutSubtreeIfNeeded()
check(contentGrid.effectiveColumns == 2 && itemFrame(0).height == 208 && itemFrame(1).height == 208 && itemFrame(0).minY == itemFrame(1).minY,
      "multi-column panel cards share the tallest preferred height within their row")
check((0..<contentClips.count / 2).allSatisfy { row in
    let left = itemFrame(row * 2)
    let right = itemFrame(row * 2 + 1)
    let expected = max(
        ClipCardView.preferredHeight(for: contentClips[row * 2], revealedText: nil, width: left.width, maximumHeight: 208),
        ClipCardView.preferredHeight(for: contentClips[row * 2 + 1], revealedText: nil, width: right.width, maximumHeight: 208))
    return abs(left.height - expected) < 1 && left.height == right.height && left.minY == right.minY && right.minX > left.minX
}, "every multi-column content row remains aligned after resizing")

contentGrid.sizesToContent = false
contentGrid.layoutSubtreeIfNeeded()
check((0..<contentClips.count).allSatisfy { itemFrame($0).height == 208 },
      "switching to fixed floating layout restores the configured equal row height")
contentGrid.sizesToContent = true
contentGrid.columns = 1
contentWindow.setContentSize(NSSize(width: 230, height: 640))
contentGrid.layoutSubtreeIfNeeded()
check(contentGrid.effectiveColumns == 1 && itemFrame(0).height == 74 && itemFrame(4).height > preferredWrapping,
      "returning to a narrow content-sized panel remeasures wrapping and short records")

// Reopening refreshes through an empty result before restoring the selected
// record. Realize the viewport synchronously, before the panel configures cards.
for contentSized in [false, true] {
    let reopening = HistoryCardsView(frame: NSRect(x: 0, y: 0, width: 444, height: 640))
    let reopeningWindow = NSWindow(contentRect: reopening.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    reopeningWindow.contentView = reopening
    reopeningWindow.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    reopeningWindow.orderFront(nil)
    var reopeningClips = (0..<80).map(fixture)
    reopening.sizesToContent = contentSized
    reopening.heightForCard = { index, width, maximum in
        ClipCardView.preferredHeight(for: reopeningClips[index], revealedText: nil,
                                     width: width, maximumHeight: maximum)
    }
    reopening.makeCard = { ClipCardView(clip: reopeningClips[$0], revealedText: nil, thumbnail: nil) { _ in } }
    reopening.layoutSubtreeIfNeeded()
    reopening.reload(count: reopeningClips.count, selectedIndex: 0, scrollToSelection: true)
    let reopeningCollection = reopening.scrollView.documentView as! NSCollectionView
    let mode = contentSized ? "content-sized" : "fixed"
    for retainedSelection in [0, 70] {
        // The first case scrolls without selecting a card. The second restores a
        // selected record far below the first viewport.
        reopening.select(retainedSelection, scrollIntoView: false)
        reopening.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 5_000))
        reopening.scrollView.reflectScrolledClipView(reopening.scrollView.contentView)
        reopeningCollection.layoutSubtreeIfNeeded()
        check(reopening.scrollView.contentView.bounds.origin.y > 4_000,
              "\(mode) reopen fixture begins deeply scrolled with selection \(retainedSelection)")
        reopeningWindow.orderOut(nil)
        reopeningWindow.orderFront(nil)
        reopeningClips = []
        reopening.reload(count: 0, selectedIndex: -1, scrollToSelection: false)
        reopeningClips = (0..<80).map(fixture)
        reopening.reload(count: reopeningClips.count, selectedIndex: retainedSelection, scrollToSelection: true)
        let visible = reopening.visibleIndices()
        check(!visible.isEmpty && visible.contains(retainedSelection),
              "\(mode) reopen immediately realizes the restored viewport for selection \(retainedSelection)")
        check(visible.allSatisfy { index in
            guard let card = reopening.card(at: index), card.superview != nil else { return false }
            return descendants(of: card).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == reopeningClips[index].text }
        }, "\(mode) reopened cards contain visible record content for selection \(retainedSelection)")
    }
    reopeningWindow.orderOut(nil)
}
print("\(checkCount) history cards checks passed")
