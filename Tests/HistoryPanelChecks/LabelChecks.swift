import AppKit
import BufferaCore
import BufferaLocalization

func labelChecks() {
    let clip = ClipSummary(id: 901, date: Date(timeIntervalSince1970: 100), kind: .text,
                           title: "Скрытая запись", text: "", source: "Fixture", byteCount: 20,
                           isConcealed: true, isFavorite: true, label: "Домашний Wi-Fi")
    let value = PanelHarness(rows: [clip])
    defer { value.finish() }
    value.cards.layoutSubtreeIfNeeded()
    waitUntil("labeled card") { value.cards.card(at: 0) != nil }
    let card = value.cards.card(at: 0)!
    let texts = descendants(of: card).compactMap { $0 as? NSTextField }.map(\.stringValue)
    check(texts.contains(clip.label) && texts.contains("••••••••"), "label is visible beside the concealed mask")
    let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: value.panel.window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
    var saves: [(Int64, String)] = []
    var completeSave: ((Error?) -> Void)?
    value.panel.onLabel = { id, label, completion in
        saves.append((id, label)); completeSave = completion
    }
    func openEditor() -> NSWindow {
        let menu = value.cards.card(at: 0)!.menu(for: event)!
        let item = menu.item(withTag: ClipCardAction.label.rawValue)!
        check(item.title == L10n.text("Подпись…"), "label menu is localized")
        menu.performActionForItem(at: menu.index(of: item))
        waitUntil("label sheet") { value.panel.window.attachedSheet != nil }
        return value.panel.window.attachedSheet!
    }
    let sheet = openEditor()
    let field = descendants(of: sheet.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    check(field.stringValue == clip.label, "label editor loads only the user label")
    check(value.panel.isInteracting, "label sheet blocks focus-loss dismissal")
    field.stringValue = "Cancelled label"
    value.panel.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    waitUntil("cancel label") { value.panel.window.attachedSheet == nil }
    check(saves.isEmpty && value.panel.selected?.label == clip.label, "cancel leaves the label unchanged")
    let nextSheet = openEditor()
    let nextField = descendants(of: nextSheet.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    nextField.stringValue = "Router login"
    value.panel.window.endSheet(nextSheet, returnCode: .alertFirstButtonReturn)
    waitUntil("save label") { saves.count == 1 }
    check(saves[0].0 == clip.id && saves[0].1 == "Router login", "save sends the label and stable record ID")
    completeSave?(HistoryError.missing)
    check(value.panel.selected?.label == clip.label, "failed save does not optimistically replace the label")
    let clearSheet = openEditor()
    let clearField = descendants(of: clearSheet.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    clearField.stringValue = ""
    value.panel.window.endSheet(clearSheet, returnCode: .alertFirstButtonReturn)
    waitUntil("clear label") { saves.count == 2 }
    check(saves[1].1.isEmpty, "empty label requests removal")
    let requestCount = value.requests.count
    completeSave?(nil)
    check(value.requests.count == requestCount + 1, "successful label save refreshes canonical history")

    let ordinary = ClipCardView(clip: fixture(902), revealedText: nil, thumbnail: nil) { _ in }
    check(ordinary.menu(for: event)!.item(withTag: ClipCardAction.label.rawValue) == nil,
          "ordinary records cannot edit labels before being favorited")
    // Render synthetic UI only, for visual review in both locales.
    let preview = ClipCardView(clip: clip, revealedText: nil, thumbnail: nil) { _ in }
    preview.frame = NSRect(x: 0, y: 0, width: 440, height: 120)
    preview.layoutSubtreeIfNeeded()
    if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/buffera-label-\(L10n.language).png"))
    }
}
