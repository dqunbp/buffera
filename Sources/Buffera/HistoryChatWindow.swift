import BufferaLocalization
import AppKit
import BufferaChat

/// Presentation only. The application owns inference, cancellation and history access.
final class HistoryChatWindow: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onNewConversation: (() -> Void)?
    var onOpenSource: ((Int64) -> Void)?
    var onShowFeatures: (() -> Void)?

    private let transcript = NSScrollView()
    private let messages = NSStackView()
    private let transcriptDocument = ChatDocumentView()
    private let composer = ChatComposer()
    private let action = HistoryAskButton(title: L10n.text("Отправить"))
    private let newConversation = NSButton(title: L10n.text("Новый разговор"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let welcome = NSStackView()
    private var currentResponse: ChatMessageView?
    private var enabled = false
    private var unavailableMessage = L10n.text("Для работы помощника скачайте модель в настройках «Поиск и ответы».")
    private var statusMessage = ""
    private var busy = false
    private var stopping = false

    init(frameAutosaveName: NSWindow.FrameAutosaveName? = "BufferaHistoryChat") {
        let window = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.title = L10n.text("Спросить Buffera")
        window.titlebarAppearsTransparent = true
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
        window.contentView?.layoutSubtreeIfNeeded()
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
        unavailableMessage = message ?? L10n.text("Для работы помощника скачайте модель в настройках «Поиск и ответы».")
        updateControls()
    }

    func beginResponse(question: String) {
        guard !busy else { return }
        welcome.isHidden = true
        append(ChatMessageView(role: L10n.text("Вы"), text: question, isQuestion: true))
        let answer = ChatMessageView(role: "Buffera", text: "", isQuestion: false)
        append(answer)
        currentResponse = answer
        composer.string = ""
        busy = true
        stopping = false
        statusMessage = L10n.text("Ищу в истории…")
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
            currentResponse.update(text: status ?? L10n.text("Ответ не получен."))
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
        action.title = busy ? L10n.text("Остановить") : L10n.text("Отправить")
        action.image = NSImage(systemSymbolName: busy ? "stop.fill" : "arrow.up", accessibilityDescription: nil)
        action.imagePosition = .imageTrailing
        action.setAccessibilityLabel(action.title)
        action.isEnabled = busy ? !stopping : enabled && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        composer.isEditable = !busy
        composer.alphaValue = busy ? 0.65 : 1
        status.stringValue = !enabled && !busy ? unavailableMessage : statusMessage
        status.textColor = .secondaryLabelColor
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
        statusMessage = L10n.text("Останавливаю…")
        updateControls()
        onStop?()
    }

    @objc private func startNewConversation() {
        guard messages.arrangedSubviews.count > 1 else { return }
        onNewConversation?()
    }

    @objc private func showFeatures() { onShowFeatures?() }

    private func build() {
        guard let window else { return }
        let root = HistoryBackdropView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = root
        let mark = NSImageView(image: BrandIdentity.appIcon(size: 80))
        mark.setAccessibilityElement(false)
        mark.widthAnchor.constraint(equalToConstant: 42).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 42).isActive = true
        let heading = NSTextField(labelWithString: L10n.text("Спросить Buffera"))
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        let subtitle = NSTextField(labelWithString: L10n.text("Локальный ИИ-помощник"))
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        for label in [heading, subtitle] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.lineBreakMode = .byTruncatingTail
        }
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
        newConversation.toolTip = L10n.text("Очистить разговор · ⌘N")
        newConversation.identifier = NSUserInterfaceItemIdentifier("chat.new")
        newConversation.setAccessibilityLabel(newConversation.title)
        newConversation.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        newConversation.imagePosition = .imageOnly
        let models = NSButton(title: L10n.text("Настройки…"), target: self, action: #selector(showFeatures))
        models.bezelStyle = .rounded
        models.controlSize = .small
        models.identifier = NSUserInterfaceItemIdentifier("chat.models")
        models.toolTip = models.title
        models.setAccessibilityLabel(models.title)
        models.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        models.imagePosition = .imageOnly
        for button in [newConversation, models] {
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        let header = NSStackView(views: [mark, identity, spacer, newConversation, models])
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
        messages.spacing = 20
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
        welcome.spacing = 14
        welcome.edgeInsets = NSEdgeInsets(top: 20, left: 6, bottom: 18, right: 6)
        let welcomeTitle = NSTextField(labelWithString: L10n.text("Что вы хотите узнать?"))
        welcomeTitle.font = .systemFont(ofSize: 26, weight: .semibold)
        let welcomeText = ChatWrappingLabel(L10n.text("Найдите нужное в истории, вспомните команду или разберитесь в сохранённом."))
        welcomeText.textColor = .secondaryLabelColor
        let example = ChatWrappingLabel(L10n.text("Например: «Найди команду для запуска проекта, которую я копировал вчера»."))
        example.font = .systemFont(ofSize: 13)
        let exampleSurface = ChatSurfaceView(.source)
        example.translatesAutoresizingMaskIntoConstraints = false
        exampleSurface.addSubview(example)
        NSLayoutConstraint.activate([
            example.leadingAnchor.constraint(equalTo: exampleSurface.leadingAnchor, constant: 16),
            example.trailingAnchor.constraint(equalTo: exampleSurface.trailingAnchor, constant: -16),
            example.topAnchor.constraint(equalTo: exampleSurface.topAnchor, constant: 14),
            example.bottomAnchor.constraint(equalTo: exampleSurface.bottomAnchor, constant: -14)
        ])
        let reassurance = ChatWrappingLabel(L10n.text("Ответы со ссылками на записи. Всё на вашем Mac.") + "\n" + L10n.text("Скрытые записи недоступны помощнику."))
        reassurance.font = .systemFont(ofSize: 12)
        reassurance.textColor = .secondaryLabelColor
        welcome.addArrangedSubview(welcomeTitle)
        welcome.addArrangedSubview(welcomeText)
        welcome.addArrangedSubview(exampleSurface)
        welcome.addArrangedSubview(reassurance)
        messages.addArrangedSubview(welcome)
        welcome.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true
        for view in [welcomeText, exampleSurface, reassurance] {
            view.widthAnchor.constraint(equalTo: welcome.widthAnchor, constant: -12).isActive = true
        }

        status.font = .systemFont(ofSize: 11)
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.identifier = NSUserInterfaceItemIdentifier("chat.status")
        let inputSurface = ChatSurfaceView(.composer)
        inputSurface.identifier = NSUserInterfaceItemIdentifier("chat.composer")
        let inputScroll = NSScrollView()
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = false
        composer.delegate = self
        composer.font = .systemFont(ofSize: 14)
        composer.textColor = .textColor
        composer.drawsBackground = false
        composer.insertionPointColor = BrandIdentity.accentColor
        composer.onFocusChanged = { [weak inputSurface] focused in inputSurface?.focused = focused }
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
        composer.setAccessibilityLabel(L10n.text("Вопрос к Buffera"))
        composer.onSend = { [weak self] in
            guard let self, !self.busy else { return }
            self.performAction()
        }
        inputScroll.documentView = composer
        let hint = NSTextField(labelWithString: L10n.text("Enter — отправить · Shift+Enter — новая строка"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        action.target = self
        action.action = #selector(performAction)
        action.identifier = NSUserInterfaceItemIdentifier("chat.send")
        action.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let footer = NSStackView(views: [hint, action])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.spacing = 14
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [inputScroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            inputSurface.addSubview(view)
        }
        for view in [header, transcript, status, inputSurface] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            transcript.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: inputSurface.topAnchor, constant: -8),
            inputSurface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            inputSurface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            inputSurface.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            inputScroll.topAnchor.constraint(equalTo: inputSurface.topAnchor, constant: 4),
            inputScroll.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: 4),
            inputScroll.trailingAnchor.constraint(equalTo: inputSurface.trailingAnchor, constant: -4),
            inputScroll.heightAnchor.constraint(equalToConstant: 70),
            inputScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: inputSurface.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: inputSurface.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: inputSurface.bottomAnchor, constant: -12)
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
    var onFocusChanged: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChanged?(false) }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let placeholder = L10n.text("Напишите вопрос об истории.")
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                                                       y: textContainerInset.height),
                withAttributes: [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.placeholderTextColor])
        }
    }

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
        body = ChatWrappingLabel(text.isEmpty ? L10n.text("Готовлю ответ…") : text)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(isQuestion ? "chat.question" : "chat.answer")
        let bubble = ChatSurfaceView(isQuestion ? .question : .answer)
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)
        let heading = NSTextField(labelWithString: role)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = isQuestion ? .secondaryLabelColor : BrandIdentity.accentColor
        body.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 11
        content.translatesAutoresizingMaskIntoConstraints = false
        if isQuestion {
            content.addArrangedSubview(heading)
        } else {
            let mark = NSImageView(image: BrandIdentity.menuBarIcon())
            mark.contentTintColor = BrandIdentity.accentColor
            mark.setAccessibilityElement(false)
            let identity = NSStackView(views: [mark, heading])
            identity.spacing = 6
            content.addArrangedSubview(identity)
        }
        content.addArrangedSubview(body)
        bubble.addSubview(content)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.widthAnchor.constraint(equalTo: widthAnchor, multiplier: isQuestion ? 0.86 : 1),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 15),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -17),
            body.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String) {
        self.text = text
        body.stringValue = text.isEmpty ? L10n.text("Готовлю ответ…") : text
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
        let heading = NSTextField(labelWithString: L10n.text("Записи из истории"))
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
            row.spacing = 4
            let surface = ChatSurfaceView(.source)
            row.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(row)
            content.addArrangedSubview(surface)
            NSLayoutConstraint.activate([
                surface.widthAnchor.constraint(equalTo: content.widthAnchor),
                row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
                row.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
                row.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10)
            ])
            button.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            sourceViews.append(surface)
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
        let date = source.copiedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale))
        detail = [source.application, date].filter { !$0.isEmpty }.joined(separator: " · ")
        super.init(frame: .zero)
        let name = source.title.isEmpty ? L10n.text("Запись") : source.title.replacingOccurrences(of: "\n", with: " ")
        title = "[\(source.number)] \(name)"
        font = .systemFont(ofSize: 12)
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        contentTintColor = BrandIdentity.accentColor
        image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        imagePosition = .imageLeading
        toolTip = L10n.text("\(name)\n\(detail)\nОткрыть в истории")
        setAccessibilityLabel(L10n.text("[\(source.number)] \(name). \(detail). Открыть в истории"))
        identifier = NSUserInterfaceItemIdentifier("chat.source.\(source.id)")
        target = self
        action = #selector(openSource)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openSource() { onOpen(sourceID) }
}
