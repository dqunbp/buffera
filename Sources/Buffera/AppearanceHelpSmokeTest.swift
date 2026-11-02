import AppKit
import BufferaCore
import BufferaLocalization

/// Uses schematic content and an invisible host, without touching saved settings or history.
func runAppearanceHelpSmokeTest(_ root: NSView) throws {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HistoryError.database(message) }
    }
    root.layoutSubtreeIfNeeded()
    let buttons = descendants(root).compactMap { $0 as? AppearanceHelpButton }
    try check(buttons.count == 3, "Appearance settings must show three help buttons")
    for topic in AppearanceHelpTopic.allCases {
        guard let button = buttons.first(where: { $0.identifier?.rawValue == "settings.appearanceHelp." + topic.rawValue }),
              let picker = descendants(root).compactMap({ $0 as? NSPopUpButton }).first(where: {
                  $0.accessibilityLabel() == topic.title
              }) else { throw HistoryError.database("Appearance help or its picker is missing: \(topic.rawValue)") }
        let frame = root.convert(button.bounds, from: button)
        let pickerFrame = root.convert(picker.bounds, from: picker)
        try check(button.topic == topic && button.bezelStyle == .helpButton &&
                  button.accessibilityLabel() == L10n.text("Пояснение: \(topic.title)") &&
                  button.toolTip == button.accessibilityLabel(), "Appearance help must identify its setting accessibly")
        try check(!button.isHiddenOrHasHiddenAncestor && root.bounds.contains(frame) &&
                  frame.minX >= pickerFrame.maxX && abs(frame.midY - pickerFrame.midY) <= 3 &&
                  frame.width >= button.intrinsicContentSize.width - 1,
                  "Appearance help must stay visible beside its picker: \(topic.rawValue)")

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let content = AppearanceHelpView(topic: topic)
            content.appearance = NSAppearance(named: appearance)
            content.setFrameSize(content.fittingSize)
            content.layoutSubtreeIfNeeded()
            let children = descendants(content)
            let fields = children.compactMap { $0 as? NSTextField }
            let diagrams = children.filter { $0.identifier?.rawValue.hasPrefix("appearanceHelp.diagram.") == true }
            try check(fields.contains { $0.stringValue == topic.title } && fields.contains { $0.stringValue == topic.detail } &&
                      diagrams.count == (topic == .placement ? 3 : 2), "Help must contain its explanation and examples")
            for view in fields.map({ $0 as NSView }) + diagrams {
                let frame = content.convert(view.bounds, from: view)
                try check(!view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0 && view.bounds.height > 0 &&
                          content.bounds.insetBy(dx: -2, dy: -2).contains(frame),
                          "Help content is clipped: \(topic.rawValue), \(view.identifier?.rawValue ?? "unknown")")
            }
            for field in fields {
                let measured = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10_000))
                try check(measured != nil && field.bounds.height >= measured!.height - 1,
                          "Help text is truncated: \(topic.rawValue), \(field.stringValue)")
            }
            content.wantsLayer = true
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw HistoryError.database("Cannot render appearance help: \(topic.rawValue)")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw HistoryError.database("Cannot encode appearance help: \(topic.rawValue)")
            }
            try data.write(to: URL(fileURLWithPath: "/tmp/buffera-appearance-help-\(topic.rawValue)-\(name)-\(L10n.language).png"))
        }
    }

    let host = AppearanceHelpSmokeWindow(contentRect: NSRect(x: 80, y: 80, width: 300, height: 150),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.alphaValue = 0
    defer { host.close() }
    host.orderFront(nil)
    try check(host.isVisible, "The invisible help test host must be available for anchoring")
    for topic in AppearanceHelpTopic.allCases {
        let button = AppearanceHelpButton(topic: topic)
        button.frame = NSRect(x: 60, y: 60, width: 25, height: 25)
        host.contentView!.addSubview(button)
        let observers = [NSPopover.willShowNotification, NSPopover.didShowNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: button.helpPopover, queue: nil) { _ in
                button.helpPopover.contentViewController?.view.window?.alphaValue = 0
            }
        }
        defer {
            observers.forEach(NotificationCenter.default.removeObserver)
            button.helpPopover.close()
            button.removeFromSuperview()
        }
        button.performClick(nil)
        try check(button.helpPopover.isShown && button.helpPopover.contentViewController?.view.window?.alphaValue == 0 &&
                  button.helpPopover.contentViewController?.view.identifier?.rawValue == "appearanceHelp." + topic.rawValue,
                  "Clicking help must open the matching anchored explanation")
        button.performClick(nil)
        try check(!button.helpPopover.isShown, "Clicking open help again must close it")
        button.performClick(nil)
        try check(button.helpPopover.isShown, "Help must reopen after being closed")
        guard let popup = button.helpPopover.contentViewController?.view.window,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popup.windowNumber,
                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                  isARepeat: false, keyCode: 53) else {
            throw HistoryError.database("Cannot construct the help Escape interaction")
        }
        popup.makeKey()
        NSApp.sendEvent(escape)
        try check(!button.helpPopover.isShown && host.isVisible,
                  "Escape must dismiss help without closing its settings host")
        button.performClick(nil)
        try check(button.helpPopover.isShown, "Help must reopen after Escape")
        button.removeFromSuperview()
        try check(!button.helpPopover.isShown, "Detaching the setting must close its help")
    }
}

private final class AppearanceHelpSmokeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}
