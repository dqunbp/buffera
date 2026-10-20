import AppKit
import BufferaChat

/// Presentation only. The application owns inference, cancellation and history access.
final class HistoryChatWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onNewConversation: (() -> Void)?
    var onOpenSource: ((Int64) -> Void)?
    var onShowModels: (() -> Void)?

    private let transcript = NSScrollView()
    private let messages = NSStackView()
    private let transcriptDocument = ChatDocumentView()
    private let composer = ChatComposer()
    private let action = NSButton(title: "Отправить", target: nil, action: nil)
    private let newConversation = NSButton(title: "Новый разговор", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let welcome = NSStackView()
    private var currentResponse: ChatMessageView?
    private var enabled = false
    private var unavailableMessage = "Скачайте и включите локального помощника в настройках моделей."
    private var statusMessage = ""
    private var busy = false
    private var stopping = false

    init(frameAutosaveName: NSWindow.FrameAutosaveName? = "BufferaHistoryChat") {
        let window = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.title = "Чат по истории"
        window.minSize = NSSize(width: 520, height: 460)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        let restored: Bool
        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
            restored = window.setFrameUsingName(frameAutosaveName)
        } else { restored = false }
        if !restored || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
            window.center()
        }
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in
            guard let self else { return }
            if self.busy { self.stopResponse() }
            else { self.window?.performClose(nil) }
        }
        window.onNewConversation = { [weak self] in self?.startNewConversation() }
        build()
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(composer)
    }

    func setAvailability(enabled: Bool, message: String? = nil) {
        self.enabled = enabled
        unavailableMessage = message ?? "Скачайте и включите локального помощника в настройках моделей."
        updateControls()
    }

    func beginResponse(question: String) {
        guard !busy else { return }
        welcome.isHidden = true
        append(ChatMessageView(role: "Вы", text: question, isQuestion: true))
        let answer = ChatMessageView(role: "Buffera", text: "", isQuestion: false)
        append(answer)
        currentResponse = answer
        composer.string = ""
        busy = true
        stopping = false
        statusMessage = "Ищу в истории…"
        updateControls()
        scrollToBottom()
    }

    /// Receives the full accumulated answer, so token batching stays outside AppKit.
    func updateResponse(text: String) {
        guard busy, let currentResponse else { return }
        let followsAnswer = isNearBottom
        currentResponse.update(text: text)
        if followsAnswer { scrollToBottom() }
    }

    func finishResponse(sources: [ChatSource], status: String? = nil) {
        guard let currentResponse else { return }
        let followsAnswer = isNearBottom
        currentResponse.showSources(sources) { [weak self] id in self?.onOpenSource?(id) }
        if currentResponse.text.isEmpty {
            currentResponse.update(text: status ?? "Ответ не получен.")
        }
        busy = false
        stopping = false
        statusMessage = status ?? ""
        self.currentResponse = nil
        updateControls()
        if followsAnswer { scrollToBottom() }
        if window?.isKeyWindow == true { window?.makeFirstResponder(composer) }
    }

    func failResponse(_ message: String) {
        let followsAnswer = isNearBottom
        if let currentResponse {
            if currentResponse.text.isEmpty { currentResponse.update(text: message) }
            else { currentResponse.showNotice(message) }
        }
        busy = false
        stopping = false
        statusMessage = message
        currentResponse = nil
        updateControls()
        if followsAnswer { scrollToBottom() }
    }

    func setStatus(_ value: String) {
        statusMessage = value
        updateControls()
    }

    func resetConversation() {
        for view in messages.arrangedSubviews where view !== welcome {
            messages.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        currentResponse = nil
        busy = false
        stopping = false
        statusMessage = ""
        welcome.isHidden = false
        composer.string = ""
        updateControls()
        if window?.isKeyWindow == true { window?.makeFirstResponder(composer) }
    }

    func windowWillClose(_ notification: Notification) {
        if busy { stopResponse() }
        else { onStop?() }
    }

    func textDidChange(_ notification: Notification) { updateControls() }

    private var isNearBottom: Bool {
        transcriptDocument.bounds.height - transcript.contentView.bounds.maxY < 70
    }

    private func append(_ message: ChatMessageView) {
        messages.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true
    }

    private func scrollToBottom() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let y = max(0, transcriptDocument.bounds.height - transcript.contentView.bounds.height)
        transcript.contentView.scroll(to: NSPoint(x: 0, y: y))
        transcript.reflectScrolledClipView(transcript.contentView)
    }

    private func updateControls() {
        action.title = busy ? "Остановить" : "Отправить"
        action.isEnabled = busy ? !stopping : enabled && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        composer.isEditable = !busy
        composer.alphaValue = busy ? 0.65 : 1
        status.stringValue = !enabled && !busy ? unavailableMessage : statusMessage
        status.textColor = !enabled && !busy ? .secondaryLabelColor : .tertiaryLabelColor
        newConversation.isEnabled = messages.arrangedSubviews.count > 1
    }

    @objc private func performAction() {
        if busy { stopResponse(); return }
        let question = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !question.isEmpty else { return }
        onSend?(question)
    }

    private func stopResponse() {
        guard busy, !stopping else { return }
        stopping = true
        statusMessage = "Останавливаю…"
        updateControls()
        onStop?()
    }

    @objc private func startNewConversation() {
        guard messages.arrangedSubviews.count > 1 else { return }
        onNewConversation?()
    }

    @objc private func showModels() { onShowModels?() }

    private func build() {
        guard let root = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Ответы по вашей истории")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Обработка на этом Mac")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let identity = NSStackView(views: [heading, subtitle])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 3
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newConversation.bezelStyle = .rounded
        newConversation.controlSize = .small
        newConversation.target = self
        newConversation.action = #selector(startNewConversation)
        newConversation.toolTip = "Очистить разговор · ⌘N"
        newConversation.identifier = NSUserInterfaceItemIdentifier("chat.new")
        let models = NSButton(title: "Модели…", target: self, action: #selector(showModels))
        models.bezelStyle = .rounded
        models.controlSize = .small
        models.identifier = NSUserInterfaceItemIdentifier("chat.models")
        let header = NSStackView(views: [identity, spacer, newConversation, models])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY

        transcript.hasVerticalScroller = true
        transcript.autohidesScrollers = true
        transcript.drawsBackground = false
        transcript.borderType = .noBorder
        transcript.identifier = NSUserInterfaceItemIdentifier("chat.transcript")
        transcriptDocument.translatesAutoresizingMaskIntoConstraints = false
        transcript.documentView = transcriptDocument
        messages.orientation = .vertical
        messages.alignment = .leading
        messages.spacing = 18
        messages.translatesAutoresizingMaskIntoConstraints = false
        transcriptDocument.addSubview(messages)
        NSLayoutConstraint.activate([
            transcriptDocument.widthAnchor.constraint(equalTo: transcript.contentView.widthAnchor),
            messages.leadingAnchor.constraint(equalTo: transcriptDocument.leadingAnchor, constant: 20),
            messages.trailingAnchor.constraint(equalTo: transcriptDocument.trailingAnchor, constant: -20),
            messages.topAnchor.constraint(equalTo: transcriptDocument.topAnchor, constant: 22),
            messages.bottomAnchor.constraint(equalTo: transcriptDocument.bottomAnchor, constant: -22)
        ])
        welcome.orientation = .vertical
        welcome.alignment = .leading
        welcome.spacing = 10
        let welcomeTitle = NSTextField(labelWithString: "Что нужно найти?")
        welcomeTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        let welcomeText = ChatWrappingLabel("Спросите о сохранённых текстах, ссылках или тексте на картинках. В ответе можно открыть записи, на которые он ссылается.")
        welcomeText.textColor = .secondaryLabelColor
        let example = ChatWrappingLabel("Например: «Найди команду для запуска проекта, которую я копировал вчера».")
        example.textColor = .secondaryLabelColor
        example.font = .systemFont(ofSize: 12)
        welcome.addArrangedSubview(welcomeTitle)
        welcome.addArrangedSubview(welcomeText)
        welcome.addArrangedSubview(example)
        messages.addArrangedSubview(welcome)
        welcome.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true
        welcomeText.widthAnchor.constraint(equalTo: welcome.widthAnchor).isActive = true
        example.widthAnchor.constraint(equalTo: welcome.widthAnchor).isActive = true

        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.identifier = NSUserInterfaceItemIdentifier("chat.status")
        let inputScroll = NSScrollView()
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .bezelBorder
        inputScroll.drawsBackground = true
        inputScroll.backgroundColor = .textBackgroundColor
        composer.delegate = self
        composer.font = .systemFont(ofSize: 14)
        composer.textColor = .textColor
        composer.backgroundColor = .textBackgroundColor
        composer.isRichText = false
        composer.importsGraphics = false
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.isAutomaticTextReplacementEnabled = false
        composer.isAutomaticSpellingCorrectionEnabled = false
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.minSize = .zero
        composer.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composer.textContainerInset = NSSize(width: 8, height: 10)
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        composer.identifier = NSUserInterfaceItemIdentifier("chat.input")
        composer.setAccessibilityLabel("Сообщение в чат")
        composer.onSend = { [weak self] in
            guard let self, !self.busy else { return }
            self.performAction()
        }
        inputScroll.documentView = composer
        let hint = NSTextField(labelWithString: "Enter — отправить · Shift+Enter — новая строка")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        action.bezelStyle = .rounded
        action.target = self
        action.action = #selector(performAction)
        action.identifier = NSUserInterfaceItemIdentifier("chat.send")
        action.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let footer = NSStackView(views: [hint, action])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 14
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let separator = NSBox()
        separator.boxType = .separator
        for view in [header, separator, transcript, status, inputScroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 15),
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: separator.bottomAnchor),
            transcript.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: inputScroll.topAnchor, constant: -8),
            inputScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            inputScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            inputScroll.heightAnchor.constraint(equalToConstant: 82),
            inputScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -9),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
    }
}

private final class ChatPanel: NSWindow {
    var onEscape: (() -> Void)?
    var onNewConversation: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            if event.keyCode == 13 { performClose(nil); return true } // ⌘W
            if event.keyCode == 45 { onNewConversation?(); return true } // ⌘N
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class ChatComposer: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, modifiers.isEmpty, !hasMarkedText() {
            window?.cancelOperation(nil)
            return
        }
        if [36, 76].contains(event.keyCode), !hasMarkedText(),
           modifiers.isEmpty || modifiers == .command {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class ChatDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ChatWrappingLabel: NSTextField {
    init(_ value: String) {
        super.init(frame: .zero)
        stringValue = value
        isEditable = false
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        font = .systemFont(ofSize: 14)
        textColor = .labelColor
        maximumNumberOfLines = 0
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5, bounds.width > 0 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }
}

private final class ChatMessageView: NSView {
    private let body: ChatWrappingLabel
    private let content = NSStackView()
    private var sourceViews: [NSView] = []
    private(set) var text: String

    init(role: String, text: String, isQuestion: Bool) {
        self.text = text
        body = ChatWrappingLabel(text.isEmpty ? "Готовлю ответ…" : text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = (isQuestion ? NSColor.controlAccentColor.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).cgColor
        let heading = NSTextField(labelWithString: role)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        body.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(heading)
        content.addArrangedSubview(body)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            body.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String) {
        self.text = text
        body.stringValue = text.isEmpty ? "Готовлю ответ…" : text
        body.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        body.invalidateIntrinsicContentSize()
    }

    func showNotice(_ text: String) {
        let notice = ChatWrappingLabel(text)
        notice.font = .systemFont(ofSize: 12)
        notice.textColor = .secondaryLabelColor
        content.addArrangedSubview(notice)
        notice.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    func showSources(_ sources: [ChatSource], onOpen: @escaping (Int64) -> Void) {
        for view in sourceViews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sourceViews = []
        guard !sources.isEmpty else { return }
        let heading = NSTextField(labelWithString: "Записи из истории")
        heading.font = .systemFont(ofSize: 11, weight: .medium)
        heading.textColor = .secondaryLabelColor
        content.addArrangedSubview(heading)
        sourceViews.append(heading)
        for source in sources {
            let button = ChatSourceButton(source: source, onOpen: onOpen)
            let detail = NSTextField(labelWithString: button.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [button, detail])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            button.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            sourceViews.append(row)
        }
    }
}

private final class ChatSourceButton: NSButton {
    private let sourceID: Int64
    private let onOpen: (Int64) -> Void
    let detail: String

    init(source: ChatSource, onOpen: @escaping (Int64) -> Void) {
        sourceID = source.id
        self.onOpen = onOpen
        let date = source.copiedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))
        detail = [source.application, date].filter { !$0.isEmpty }.joined(separator: " · ")
        super.init(frame: .zero)
        let name = source.title.isEmpty ? "Запись" : source.title.replacingOccurrences(of: "\n", with: " ")
        title = "[\(source.number)] \(name)"
        font = .systemFont(ofSize: 12)
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        contentTintColor = .controlAccentColor
        image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        imagePosition = .imageLeading
        toolTip = "\(name)\n\(detail)\nОткрыть в истории"
        setAccessibilityLabel("[\(source.number)] \(name). \(detail). Открыть в истории")
        identifier = NSUserInterfaceItemIdentifier("chat.source.\(source.id)")
        target = self
        action = #selector(openSource)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openSource() { onOpen(sourceID) }
}
