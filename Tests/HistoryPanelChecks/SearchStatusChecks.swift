import AppKit
import BufferaCore
import BufferaLocalization

func searchStatusChecks() {
    let value = PanelHarness(rows: [fixture(1)])
    defer { value.panel.close(restoreFocus: false); value.finish() }
    // The harness may restore the user's narrow saved frame; check translations
    // at a fixed size without persisting a change to that frame.
    value.panel.window.setContentSize(NSSize(width: 640, height: 600))
    let views = descendants(of: value.panel.window.contentView!)
    let semantic = views.compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == "history.searchMode" }!
    func expect(_ query: String, _ message: L10n.Message) {
        value.search.stringValue = query
        value.panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: value.search))
        value.panel.window.contentView?.layoutSubtreeIfNeeded()
        let label = views.compactMap { $0 as? NSTextField }.first { $0.stringValue == L10n.text(message) }
        check(label != nil && label?.isHiddenOrHasHiddenAncestor == false,
              "\(L10n.language): query \(String(reflecting: query)) shows \(L10n.text(message))")
        if let label {
            check(label.bounds.width >= label.intrinsicContentSize.width,
                  "\(L10n.language): \(L10n.text(message)) fits its label (\(label.bounds.width) >= \(label.intrinsicContentSize.width))")
        }
    }

    expect("", "Загружаем историю…")
    expect(" \n\t", "Загружаем историю…")
    for query in ["a", "аб", "  ab \n", "e\u{301}🙂"] {
        expect(query, "Ищу совпадения…")
    }
    expect("abc", "Ищу смыслы…")
    expect("  абв\n", "Ищу смыслы…")
    expect("ab", "Ищу совпадения…")
    semantic.performClick(nil)
    expect("long query", "Ищу совпадения…")
    semantic.performClick(nil)
    expect("long query", "Ищу смыслы…")
    value.panel.updateFeatureAvailability(semanticSearch: false, chat: true)
    expect("long query", "Ищу совпадения…")
    value.panel.receive([fixture(2)], total: 1, offset: 0)
    check(!views.compactMap { $0 as? NSTextField }.contains {
        [L10n.text("Ищу смыслы…"), L10n.text("Ищу совпадения…")].contains($0.stringValue)
    }, "completed search replaces the loading status")
}
