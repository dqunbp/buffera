import AppKit
import BufferaCore

/// Previews a derived value; the caller owns both source loading and clipboard writes.
final class CopyTransformSheet: NSObject {
    var onRequest: ((CopyTransformOperation, @escaping (Result<String, Error>) -> Void) -> Void)?
    var onCopy: ((String, @escaping (Error?) -> Void) -> Void)?
    var onClose: ((Bool) -> Void)?
    private(set) var isShown = false

    private let sheet = CopyTransformWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    private let operation = NSPopUpButton()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancel = NSButton(title: "Отмена", target: nil, action: nil)
    private let copy = NSButton(title: "В буфер", target: nil, action: nil)
    private weak var parentWindow: NSWindow?
    private var operations: [CopyTransformOperation] = []
    private var result: String?
    private var epoch: UInt64 = 0
    private var presentation: UInt64 = 0
    private var copying = false
    private var awaitingResult = false

    override init() {
        super.init()
        sheet.title = "Скопировать иначе"
        sheet.isReleasedWhenClosed = false
        sheet.hidesOnDeactivate = false
        sheet.animationBehavior = .none
        sheet.onCancel = { [weak self] in self?.close() }
        sheet.onConfirm = { [weak self] in self?.copy.performClick(nil) }
        buildContent()
    }

    func show(for clip: ClipSummary, relativeTo parent: NSWindow) {
        close()
        let available = CopyTransformOperation.available(for: clip)
        guard parent.isVisible, parent.attachedSheet == nil, !available.isEmpty else { return }
        operations = available
        operation.removeAllItems()
        operation.addItems(withTitles: available.map(\.title))
        operation.selectItem(at: 0)
        parentWindow = parent
        isShown = true
        let screen = parent.screen?.visibleFrame.size ?? NSSize(width: 1_024, height: 768)
        let width = min(max(480, min(660, parent.frame.width)), max(320, screen.width - 40))
        let height = min(460, max(300, screen.height - 90))
        sheet.contentMinSize = NSSize(width: min(480, width), height: min(340, height))
        sheet.setContentSize(NSSize(width: width, height: height))
        presentation &+= 1
        let currentPresentation = presentation
        parent.beginSheet(sheet) { [weak self] _ in
            guard let self, self.isShown, self.presentation == currentPresentation else { return }
            self.finish(copied: false)
        }
        sheet.makeFirstResponder(operation)
        requestResult()
    }

    func close() { finish(copied: false) }

    private func finish(copied: Bool) {
        guard isShown else { return }
        isShown = false
        epoch &+= 1
        presentation &+= 1
        result = nil
        awaitingResult = false
        copying = false
        preview.string = ""
        status.stringValue = ""
        detail.stringValue = ""
        operations.removeAll()
        operation.removeAllItems()
        operation.isEnabled = false
        copy.isEnabled = false
        progress.stopAnimation(nil)
        let parent = parentWindow
        parentWindow = nil
        if let sheetParent = sheet.sheetParent { sheetParent.endSheet(sheet, returnCode: copied ? .OK : .cancel) }
        sheet.orderOut(nil)
        if parent?.isVisible == true { parent?.makeKey() }
        onClose?(copied)
    }

    @objc private func operationChanged() { requestResult() }
    @objc private func cancelled() { close() }

    private func requestResult() {
        guard isShown, !copying, operations.indices.contains(operation.indexOfSelectedItem) else { return }
        epoch &+= 1
        let requestEpoch = epoch
        let selected = operations[operation.indexOfSelectedItem]
        result = nil
        awaitingResult = true
        preview.string = ""
        detail.stringValue = selected.detail
        operation.isEnabled = operations.count > 1
        copy.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.stringValue = "Готовим текст…"
        progress.startAnimation(nil)
        guard let onRequest else {
            receive(.failure(CopyTransformSheetError.unavailable), epoch: requestEpoch)
            return
        }
        onRequest(selected) { [weak self] value in
            if Thread.isMainThread {
                self?.receive(value, epoch: requestEpoch)
            } else {
                DispatchQueue.main.async { [weak self] in self?.receive(value, epoch: requestEpoch) }
            }
        }
    }

    private func receive(_ value: Result<String, Error>, epoch requestEpoch: UInt64) {
        guard isShown, epoch == requestEpoch, awaitingResult, !copying else { return }
        awaitingResult = false
        progress.stopAnimation(nil)
        switch value {
        case .success(let text):
            result = text
            let prefix = text.prefix(500_000)
            let truncated = prefix.endIndex != text.endIndex
            preview.string = String(prefix)
            preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
            status.textColor = .secondaryLabelColor
            if text.isEmpty {
                status.stringValue = "После преобразования текст пуст. Выберите другой вариант."
            } else if truncated {
                status.stringValue = "Показаны первые 500 000 символов. В буфер попадёт весь текст."
            } else {
                status.stringValue = "В буфер попадёт текст из предпросмотра."
            }
            copy.isEnabled = !text.isEmpty && onCopy != nil
        case .failure(let error):
            result = nil
            preview.string = ""
            status.textColor = .systemRed
            status.stringValue = error.localizedDescription
            copy.isEnabled = false
        }
    }

    @objc private func copyResult() {
        guard isShown, !copying, !awaitingResult, let result, !result.isEmpty, let onCopy else { return }
        copying = true
        epoch &+= 1
        let copyEpoch = epoch
        operation.isEnabled = false
        copy.isEnabled = false
        status.textColor = .secondaryLabelColor
        status.stringValue = "Копируем…"
        progress.startAnimation(nil)
        onCopy(result) { [weak self] error in
            if Thread.isMainThread {
                self?.didCopy(error: error, epoch: copyEpoch)
            } else {
                DispatchQueue.main.async { [weak self] in self?.didCopy(error: error, epoch: copyEpoch) }
            }
        }
    }

    private func didCopy(error: Error?, epoch copyEpoch: UInt64) {
        guard isShown, epoch == copyEpoch, copying else { return }
        copying = false
        progress.stopAnimation(nil)
        if let error {
            operation.isEnabled = operations.count > 1
            copy.isEnabled = result?.isEmpty == false
            status.textColor = .systemRed
            status.stringValue = error.localizedDescription
        } else {
            finish(copied: true)
        }
    }

    private func buildContent() {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Скопировать иначе")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        operation.target = self
        operation.action = #selector(operationChanged)
        operation.setAccessibilityLabel("Вариант копирования")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3
        detail.setContentCompressionResistancePriority(.required, for: .vertical)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textColor = .labelColor
        preview.backgroundColor = .textBackgroundColor
        preview.textContainerInset = NSSize(width: 10, height: 10)
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]
        preview.minSize = .zero
        preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        preview.textContainer?.widthTracksTextView = true
        preview.textContainer?.containerSize = NSSize(width: 550, height: CGFloat.greatestFiniteMagnitude)
        preview.setAccessibilityLabel("Результат преобразования")
        scroll.documentView = preview

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.setAccessibilityLabel("Состояние преобразования")
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelled)
        cancel.keyEquivalent = "\u{1b}"
        copy.bezelStyle = .rounded
        copy.target = self
        copy.action = #selector(copyResult)
        copy.keyEquivalent = "\r"
        sheet.defaultButtonCell = copy.cell as? NSButtonCell

        for child in [heading, operation, detail, scroll, progress, status, cancel, copy] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            operation.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            operation.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            operation.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            detail.topAnchor.constraint(equalTo: operation.bottomAnchor, constant: 7),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            progress.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            progress.topAnchor.constraint(equalTo: status.topAnchor, constant: 1),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14),
            status.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 7),
            status.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -14),
            copy.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            copy.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            cancel.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: copy.centerYAnchor)
        ])
        sheet.contentView = root
    }
}

private enum CopyTransformSheetError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Преобразование сейчас недоступно." }
}

private final class CopyTransformWindow: NSPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && modifiers.isEmpty || event.keyCode == 13 && modifiers == .command {
            onCancel?()
            return true
        }
        if [36, 76].contains(event.keyCode), modifiers.isEmpty {
            onConfirm?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
