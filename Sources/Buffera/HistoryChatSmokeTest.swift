import BufferaLocalization
import AppKit
import BufferaChat
import BufferaCore

/// Runs without opening windows, calling a model or touching either clipboard or history.
func runHistoryChatSmokeTest() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let chat = HistoryChatWindow(frameAutosaveName: nil)
    guard let window = chat.window, let content = window.contentView else {
        throw HistoryError.database("Chat window was not constructed")
    }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HistoryError.database(message) }
    }
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    func control<T: NSView>(_ identifier: String, as type: T.Type) throws -> T {
        guard let control = descendants(content).first(where: { $0.identifier?.rawValue == identifier }) as? T else {
            throw HistoryError.database("Missing chat control: \(identifier)")
        }
        return control
    }
    func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "\r") throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else {
            throw HistoryError.database("Could not create chat key event")
        }
        return event
    }
    let input = try control("chat.input", as: NSTextView.self)
    let send = try control("chat.send", as: NSButton.self)
    let reset = try control("chat.new", as: NSButton.self)
    let status = try control("chat.status", as: NSTextField.self)
    var sent: [String] = []
    var stops = 0
    var opened: [Int64] = []
    var resets = 0
    chat.onSend = { sent.append($0) }
    chat.onStop = { stops += 1 }
    chat.onOpenSource = { opened.append($0) }
    chat.onNewConversation = { resets += 1; chat.resetConversation() }

    // Match show(): AppKit's text interpretation needs the composer as first responder.
    try check(window.makeFirstResponder(input), "Could not focus the chat composer")
    input.string = "  Найди команду  "
    chat.textDidChange(Notification(name: NSText.didChangeNotification))
    try check(!send.isEnabled, "Disabled model allowed sending")
    input.keyDown(with: try key(36))
    try check(sent.isEmpty, "Enter submitted without an enabled model")
    chat.setAvailability(enabled: true)
    try check(send.isEnabled, "Enabled model did not allow a nonempty question")
    input.keyDown(with: try key(36))
    try check(sent == ["Найди команду"], "Enter did not submit the trimmed question")
    input.string = "Новая строка"
    input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
    input.keyDown(with: try key(36, modifiers: .shift))
    try check(sent.count == 1 && input.string.contains("\n"), "Shift+Enter sent instead of adding a line")
    input.keyDown(with: try key(36, modifiers: .command))
    try check(sent.count == 2, "Command+Enter did not submit")

    chat.beginResponse(question: "Найди команду")
    try check(!input.isEditable && send.title == L10n.text("Остановить"), "Streaming controls remained in send mode")
    input.keyDown(with: try key(36))
    try check(stops == 0 && sent.count == 2, "Enter during streaming unexpectedly stopped or resubmitted")
    chat.updateResponse(text: "Команда: swift build [3].\nПовторить её можно из папки проекта.")
    window.setContentSize(NSSize(width: 520, height: 460))
    content.layoutSubtreeIfNeeded()
    for control in [send as NSView, input, reset] {
        let bounds = control.convert(control.bounds, to: content)
        try check(bounds.minX >= -1 && bounds.maxX <= content.bounds.maxX + 1,
                  "Chat control extends outside minimum window width")
    }
    let source = ChatSource(number: 3, id: 9_007_199_254_740_993,
        title: "Сборка проекта", copiedAt: Date(timeIntervalSince1970: 1_800_000_000),
        application: "Terminal")
    chat.finishResponse(sources: [source])
    try check(input.isEditable && send.title == L10n.text("Отправить"), "Completed response did not restore composer")
    let sourceButton = try control("chat.source.\(source.id)", as: NSButton.self)
    sourceButton.performClick(nil)
    try check(opened == [source.id], "Source action lost precision or did not use its typed ID")
    try check(sourceButton.title.contains("[3]"), "Source reference was renumbered")
    try check(descendants(content).compactMap { ($0 as? NSTextField)?.stringValue }.contains(where: {
        $0.contains("Terminal") && $0.contains("·")
    }), "Source application and date were not visible")

    chat.beginResponse(question: "Ещё один вопрос")
    chat.updateResponse(text: "Частичный ответ")
    input.keyDown(with: try key(53, characters: "\u{1b}"))
    try check(stops == 1 && !send.isEnabled, "Escape did not request cancellation once")
    window.cancelOperation(nil)
    try check(stops == 1, "Repeated Escape duplicated cancellation")
    chat.finishResponse(sources: [], status: "Ответ остановлен.")
    chat.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    try check(stops == 2, "Closing an idle chat did not release its runtime")
    try check(reset.isEnabled, "Closing erased the in-memory conversation")
    reset.performClick(nil)
    try check(resets == 1 && !reset.isEnabled, "New conversation did not clear the transcript")
    try check(!descendants(content).contains(where: { $0.identifier?.rawValue.hasPrefix("chat.source.") == true }),
              "Reset kept old source actions")
    chat.updateResponse(text: "Late cancelled tokens")
    try check(!descendants(content).compactMap { ($0 as? NSTextField)?.stringValue }.contains("Late cancelled tokens"),
              "Late tokens were displayed after reset")
    chat.setAvailability(enabled: false, message: "Включите помощника")
    try check(status.stringValue == "Включите помощника", "Unavailable model guidance was lost")
    try check(!window.isVisible, "UI checks unexpectedly opened a window")
}
