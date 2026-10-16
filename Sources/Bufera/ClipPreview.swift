import AppKit
import BuferaCore
import ImageIO

enum ClipPreviewContent {
    case text(String)
    case image(NSImage)
    case unavailable(String)

    // Callers must exclude concealed entries before asking for preview content.
    static func decode(_ payload: ClipPayload, kind: ClipKind) -> ClipPreviewContent {
        switch kind {
        case .text, .link:
            guard let text = ClipboardService.revealedText(payload), !text.isEmpty else {
                return .unavailable("В этой записи нет текста для просмотра.")
            }
            return .text(limited(text))
        case .image:
            for representation in payload.items.joined() where
                [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue].contains(representation.type) {
                guard let source = CGImageSourceCreateWithData(representation.data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1_600,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { continue }
                return .image(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
            }
            return .unavailable("Не удалось показать картинку. Исходные данные сохранены в истории.")
        case .file:
            let paths = payload.items.compactMap { representations -> String? in
                guard let representation = representations.first(where: { $0.type == NSPasteboard.PasteboardType.fileURL.rawValue }),
                      let value = String(data: representation.data, encoding: .utf8),
                      let url = URL(string: value), url.isFileURL else { return nil }
                return url.path
            }
            return paths.isEmpty ? .unavailable("Пути к файлам недоступны для просмотра.") : .text(limited(paths.joined(separator: "\n\n")))
        case .other:
            let representations = payload.items.flatMap { $0 }
            let formats = Dictionary(grouping: representations, by: \.type).sorted { $0.key < $1.key }
            let lines = formats.prefix(40).map { type, values in
                let bytes = values.reduce(0) { $0 + $1.data.count }
                return "\(String(type.prefix(180))) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
            }
            guard !lines.isEmpty else { return .unavailable("В записи нет данных для просмотра.") }
            let extra = formats.count > 40 ? "\n… и ещё \(formats.count - 40) форматов" : ""
            return .text("Форматы записи\n\n" + lines.joined(separator: "\n") + extra)
        }
    }

    private static func limited(_ text: String) -> String {
        let prefix = text.prefix(500_000)
        guard prefix.endIndex != text.endIndex else { return text }
        return String(prefix) + "\n\n— Показаны первые 500 000 символов. Копируется запись целиком. —"
    }
}

final class ClipPreview: NSObject, NSPopoverDelegate {
    var onClose: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var isShown: Bool { popover.isShown }

    private let popover = NSPopover()
    private weak var parentWindow: NSWindow?
    private var keyMonitor: Any?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    deinit { removeKeyMonitor() }

    func show(_ content: ClipPreviewContent, title: String, relativeTo view: NSView) {
        guard let window = view.window, window.isVisible else { return }
        close()
        parentWindow = window
        let screenSize = window.screen?.visibleFrame.size ?? NSSize(width: 1_024, height: 768)
        let size = NSSize(width: min(520, max(240, screenSize.width - 48)),
                          height: min(420, max(200, screenSize.height - 48)))
        let controller = PreviewViewController(content: content, title: title, size: size)
        popover.contentViewController = controller
        popover.contentSize = size
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        controller.view.window?.makeKey()
        if let textView = controller.textView { controller.view.window?.makeFirstResponder(textView) }
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        if popover.isShown { popover.close() }
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
        // Releasing the controller also releases the decoded preview content.
        popover.contentViewController = nil
        parentWindow = nil
        onClose?()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown,
                  let previewWindow = self.popover.contentViewController?.view.window,
                  event.window === previewWindow else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 53, 49: // Escape, Space
                self.closeFromKeyboard()
            case 36, 76: // Return, keypad Enter
                self.closeFromKeyboard()
                self.onConfirm?()
            case 125, 126: // Down, Up
                self.closeFromKeyboard()
                self.onMove?(event.keyCode == 125 ? 1 : -1)
            default:
                return event
            }
            return nil
        }
    }

    private func closeFromKeyboard() {
        let parent = parentWindow
        close()
        if parent?.isVisible == true { parent?.makeKey() }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }
}

private final class PreviewViewController: NSViewController {
    private let content: ClipPreviewContent
    private let heading: String
    private let size: NSSize
    private(set) var textView: NSTextView?

    init(content: ClipPreviewContent, title: String, size: NSSize) {
        self.content = content; heading = title; self.size = size
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        let hint = NSTextField(labelWithString: "Пробел — закрыть   ↵ — выбрать   ↑↓ — перейти")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        let body: NSView
        switch content {
        case .text(let value):
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width - 32, height: size.height - 84))
            text.string = value
            text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.drawsBackground = false
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            text.textContainerInset = NSSize(width: 2, height: 4)
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.minSize = .zero
            text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(width: size.width - 32, height: CGFloat.greatestFiniteMagnitude)
            text.setAccessibilityLabel("Содержимое записи")
            scroll.documentView = text
            textView = text
            body = scroll
        case .image(let image):
            let imageView = NSImageView()
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.setAccessibilityLabel("Просмотр картинки")
            body = imageView
        case .unavailable(let message):
            let label = NSTextField(wrappingLabelWithString: message)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            body = label
        }
        for child in [title, body, hint] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            body.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -10),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        view = root
    }
}
