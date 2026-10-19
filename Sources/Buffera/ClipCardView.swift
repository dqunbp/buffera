import AppKit
import BufferaCore

enum ClipCardAction: Int, CaseIterable {
    case copy, preview, favorite, reveal, finder, save, delete, nearby, copyDifferently

    var title: String {
        switch self {
        case .copy: return "В буфер"
        case .preview: return "Просмотр"
        case .favorite: return "В избранное"
        case .reveal: return "Показать содержимое"
        case .finder: return "Показать в Finder"
        case .save: return "Сохранить как…"
        case .delete: return "Удалить запись"
        case .nearby: return "Показать рядом"
        case .copyDifferently: return "Скопировать иначе"
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "doc.on.clipboard"
        case .preview: return "arrow.up.left.and.arrow.down.right"
        case .favorite: return "star"
        case .reveal: return "eye"
        case .finder: return "folder"
        case .save: return "square.and.arrow.down"
        case .delete: return "trash"
        case .nearby: return "clock"
        case .copyDifferently: return "text.badge.checkmark"
        }
    }

    var shortcut: String {
        switch self {
        case .copy: return "↩"
        case .preview: return "Пробел / ⌘Y"
        case .favorite: return "⌘D"
        case .reveal: return "⇧⌘H"
        case .finder: return "⇧⌘R"
        case .save: return "⇧⌘S"
        case .delete: return "⌘⌫"
        case .nearby: return "⇧⌘N"
        case .copyDifferently: return "⇧⌘C"
        }
    }

    var keyEquivalent: String {
        switch self {
        case .copy: return ""
        case .preview: return "y"
        case .favorite: return "d"
        case .reveal: return "h"
        case .finder: return "r"
        case .save: return "s"
        case .delete: return "\u{8}"
        case .nearby: return "n"
        case .copyDifferently: return "c"
        }
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        switch self {
        case .copy: return []
        case .reveal, .finder, .save, .nearby, .copyDifferently: return [.command, .shift]
        case .preview, .favorite, .delete: return .command
        }
    }

    func isAvailable(for clip: ClipSummary) -> Bool {
        switch self {
        case .reveal: return clip.isConcealed || clip.kind == .text || clip.kind == .link
        case .finder, .save: return clip.kind == .image && !clip.isConcealed
        case .copyDifferently: return !clip.isConcealed && [.text, .link, .image].contains(clip.kind)
        case .copy, .preview, .favorite, .delete, .nearby: return true
        }
    }

    func title(for clip: ClipSummary, isRevealed: Bool) -> String {
        switch self {
        case .favorite: return clip.isFavorite ? "Убрать из избранного" : title
        case .reveal:
            return !clip.isConcealed || isRevealed ? "Скрыть содержимое" : title
        default: return title
        }
    }

    func symbol(for clip: ClipSummary, isRevealed: Bool) -> String {
        switch self {
        case .favorite: return clip.isFavorite ? "star.fill" : symbol
        case .reveal: return !clip.isConcealed || isRevealed ? "eye.slash" : symbol
        default: return symbol
        }
    }
}

/// A card contains presentation and callbacks only; the panel owns selection and mutations.
final class ClipCardView: NSTableCellView, NSMenuDelegate {
    private static let maximumPreviewLines = 12
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()
    private var clip: ClipSummary
    private let isRevealed: Bool
    private let onAction: (ClipCardAction) -> Void
    private let thumbnailView = NSImageView()
    private let contentText = ClipCardView.makeContentText()
    private var thumbnailWidth: NSLayoutConstraint?
    private var thumbnailHeight: NSLayoutConstraint?
    private let quickShortcut = NSTextField(labelWithString: "")
    private var buttons: [ClipCardAction: NSButton] = [:]
    private var selected = false
    private var nearbyAnchor = false
    private var quickNumber: Int?
    private var actionsEnabled = true
    private var copyTransformOperations: [CopyTransformOperation]?
    private weak var activeCopyTransformMenu: CopyTransformMenu?
    var onMenuTracking: ((Bool) -> Void)?
    var onSelect: (() -> Void)?
    var onActivate: (() -> Void)?
    var onRequestCopyTransformOperations: (() -> Void)?
    var onCopyTransform: ((CopyTransformOperation) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        updateContentSizing(for: newSize)
        super.setFrameSize(newSize)
    }

    override func layout() {
        updateContentSizing(for: bounds.size)
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Text and thumbnails are a single selectable card surface. Keep actual
        // action buttons interactive without exposing NSTextField's text menu.
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            if view is NSButton { return hit }
            ancestor = view.superview
        }
        return self
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelect?()
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onSelect else { super.mouseDown(with: event); return }
        onSelect()
        if event.clickCount == 2 { onActivate?() }
    }

    /// The docked history sizes records using exactly the text the card exposes.
    /// In particular, a concealed record never leaks its length through layout.
    static func preferredHeight(for clip: ClipSummary, revealedText: String?,
                                width: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        let width = width.isFinite ? max(1, width) : 1
        let maximumHeight = maximumHeight.isFinite ? max(74, maximumHeight) : 74
        if clip.kind == .image && !clip.isConcealed {
            return 50 + thumbnailSize(contentHeight: maximumHeight - 50, width: width)
        }
        let text = makeContentText()
        text.stringValue = shownText(for: clip, revealedText: revealedText)
        text.maximumNumberOfLines = 0
        let textWidth = contentTextWidth(cardWidth: width, iconWidth: 24)
        text.preferredMaxLayoutWidth = textWidth
        let measured = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth,
                                                           height: .greatestFiniteMagnitude)).height ?? 24
        let visibleTextHeight = min(ceil(measured), CGFloat(maximumPreviewLines) * lineHeight(for: text.font))
        return min(maximumHeight, 50 + max(24, visibleTextHeight))
    }

    init(clip: ClipSummary, revealedText: String?, thumbnail: NSImage?,
         onAction: @escaping (ClipCardAction) -> Void) {
        self.clip = clip
        isRevealed = clip.isConcealed && revealedText != nil
        self.onAction = onAction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        build(revealedText: revealedText)
        if let thumbnail { setThumbnail(thumbnail) }
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateAppearance()
    }

    func setNearbyAnchor(_ value: Bool) {
        nearbyAnchor = value
        updateQuickLabel()
        updateAppearance()
    }

    func setThumbnail(_ image: NSImage) {
        guard clip.kind == .image, !clip.isConcealed else { return }
        thumbnailView.image = image
        thumbnailView.contentTintColor = nil
    }

    func setQuickShortcut(_ number: Int?) {
        quickNumber = number.flatMap { (1...9).contains($0) ? $0 : nil }
        updateQuickLabel()
    }

    private func updateQuickLabel() {
        if let number = quickNumber {
            quickShortcut.stringValue = "⌘\(number)"
            quickShortcut.setAccessibilityLabel("Выбрать запись, Command \(number)")
        } else {
            quickShortcut.stringValue = nearbyAnchor ? "●" : ""
            quickShortcut.setAccessibilityLabel(nearbyAnchor ? "Опорная запись" : nil)
        }
        quickShortcut.textColor = nearbyAnchor ? .controlAccentColor : .labelColor
        quickShortcut.toolTip = nearbyAnchor ? "Опорная запись — соседи показаны вокруг этого копирования" : nil
        quickShortcut.isHidden = quickNumber == nil && !nearbyAnchor
    }

    func setActionsEnabled(_ enabled: Bool) {
        actionsEnabled = enabled
        buttons.values.forEach { $0.isEnabled = enabled }
        activeCopyTransformMenu?.setActionsEnabled(enabled)
    }

    func setCopyTransformOperations(_ operations: [CopyTransformOperation]?) {
        copyTransformOperations = operations
        buttons[.copyDifferently]?.isHidden = operations?.isEmpty == true
        activeCopyTransformMenu?.setOperations(operations)
    }

    func showCopyTransformMenu() {
        guard actionsEnabled, ClipCardAction.copyDifferently.isAvailable(for: clip),
              copyTransformOperations?.isEmpty != true else { return }
        onSelect?()
        let menu = makeCopyTransformMenu()
        menu.delegate = self
        let anchor = buttons[.copyDifferently]?.frame ?? bounds
        let point = buttons[.copyDifferently].map {
            $0.convert(NSPoint(x: 0, y: 0), to: self)
        } ?? NSPoint(x: anchor.minX, y: anchor.minY)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func makeCopyTransformMenu() -> CopyTransformMenu {
        if copyTransformOperations == nil { onRequestCopyTransformOperations?() }
        let menu = CopyTransformMenu(operations: copyTransformOperations) { [weak self] operation in
            guard let self, self.actionsEnabled,
                  ClipCardAction.copyDifferently.isAvailable(for: self.clip),
                  self.copyTransformOperations?.contains(operation) == true else { return }
            self.onCopyTransform?(operation)
        }
        menu.setActionsEnabled(actionsEnabled)
        activeCopyTransformMenu = menu
        return menu
    }

    func updateFavorite(_ updatedClip: ClipSummary) {
        guard updatedClip.id == clip.id else { return }
        clip = updatedClip
        if let button = buttons[.favorite] { configureButton(button, for: .favorite) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard actionsEnabled else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for action in ClipCardAction.allCases where action.isAvailable(for: clip) {
            if action == .copyDifferently && copyTransformOperations?.isEmpty == true { continue }
            if action == .delete { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title(for: clip, isRevealed: isRevealed),
                                  action: #selector(menuAction(_:)), keyEquivalent: action.keyEquivalent)
            item.keyEquivalentModifierMask = action.keyEquivalentModifierMask
            item.image = NSImage(systemSymbolName: action.symbol(for: clip, isRevealed: isRevealed),
                                 accessibilityDescription: nil)
            item.tag = action.rawValue
            item.target = self
            if action == .copyDifferently {
                item.action = nil
                item.submenu = makeCopyTransformMenu()
            }
            menu.addItem(item)
        }
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuTracking?(false) }

    @objc private func buttonAction(_ sender: NSButton) { dispatchAction(tag: sender.tag) }
    @objc private func menuAction(_ sender: NSMenuItem) { dispatchAction(tag: sender.tag) }

    private func dispatchAction(tag: Int) {
        guard actionsEnabled, let action = ClipCardAction(rawValue: tag), action.isAvailable(for: clip) else { return }
        onAction(action)
    }

    private func build(revealedText: String?) {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let isImage = clip.kind == .image && !clip.isConcealed
        let iconSize: CGFloat = isImage ? 56 : 24
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.image = NSImage(systemSymbolName: clip.isConcealed ? "lock.fill" : clip.kind.symbol,
                                      accessibilityDescription: clip.isConcealed ? "Скрытая запись" : clip.kind.label)
        thumbnailView.imageScaling = isImage ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        thumbnailView.contentTintColor = .secondaryLabelColor
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 5
        thumbnailView.layer?.masksToBounds = true
        content.addSubview(thumbnailView)

        let text = contentText
        text.stringValue = Self.shownText(for: clip, revealedText: revealedText)
        text.translatesAutoresizingMaskIntoConstraints = false
        if clip.isConcealed && !isRevealed { text.setAccessibilityLabel("Скрытая запись") }
        // Full content is opened by an explicit preview, never an incidental hover.
        text.toolTip = nil
        content.addSubview(text)

        quickShortcut.translatesAutoresizingMaskIntoConstraints = false
        quickShortcut.isEditable = false
        quickShortcut.isSelectable = false
        quickShortcut.font = .systemFont(ofSize: 11, weight: .medium)
        quickShortcut.textColor = .secondaryLabelColor
        quickShortcut.alignment = .right
        quickShortcut.isHidden = true
        content.addSubview(quickShortcut)

        let metadata = NSTextField(labelWithString: metadataText())
        metadata.isEditable = false
        metadata.isSelectable = false
        metadata.font = .systemFont(ofSize: 11)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        metadata.toolTip = clip.date.formatted(date: .complete, time: .standard)
        metadata.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metadata.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        metadata.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true

        let footer = NSStackView(views: [metadata])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.spacing = 3
        // Keep the most frequent final action at the right edge across all kinds.
        let footerActions: [ClipCardAction] = [.favorite, .nearby, .reveal, .finder, .save, .preview, .copyDifferently, .copy]
        for action in footerActions where action.isAvailable(for: clip) {
            let button = makeButton(action)
            buttons[action] = button
            footer.addArrangedSubview(button)
        }
        addSubview(footer)

        thumbnailWidth = thumbnailView.widthAnchor.constraint(equalToConstant: iconSize)
        thumbnailHeight = thumbnailView.heightAnchor.constraint(equalToConstant: iconSize)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            thumbnailView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            thumbnailView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            thumbnailWidth!, thumbnailHeight!,
            text.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: quickShortcut.leadingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            quickShortcut.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            quickShortcut.topAnchor.constraint(equalTo: content.topAnchor),
            quickShortcut.widthAnchor.constraint(equalToConstant: 27),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    private func updateContentSizing(for size: NSSize) {
        // The action footer remains fixed while extra height goes to the preview.
        let contentHeight = max(24, size.height - 50)
        let lineHeight = Self.lineHeight(for: contentText.font)
        let lines = max(1, min(Self.maximumPreviewLines, Int(floor(contentHeight / lineHeight))))
        if contentText.maximumNumberOfLines != lines { contentText.maximumNumberOfLines = lines }
        var iconWidth: CGFloat = 24
        if clip.kind == .image, !clip.isConcealed {
            // Reserve room for the image label and quick-selection badge in a
            // narrow column; wider/taller cards can show up to a 144 pt preview.
            let thumbnailSize = Self.thumbnailSize(contentHeight: contentHeight, width: size.width)
            iconWidth = thumbnailSize
            if thumbnailWidth?.constant != thumbnailSize { thumbnailWidth?.constant = thumbnailSize }
            if thumbnailHeight?.constant != thumbnailSize { thumbnailHeight?.constant = thumbnailSize }
        }
        let textWidth = Self.contentTextWidth(cardWidth: size.width, iconWidth: iconWidth)
        if contentText.preferredMaxLayoutWidth != textWidth { contentText.preferredMaxLayoutWidth = textWidth }
    }

    private static func shownText(for clip: ClipSummary, revealedText: String?) -> String {
        if clip.isConcealed { return revealedText.map { String($0.prefix(4_000)) } ?? "••••••••" }
        if (clip.kind == .text || clip.kind == .link), !clip.text.isEmpty {
            return String(clip.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        }
        return clip.title
    }

    private static func makeContentText() -> NSTextField {
        let text = NSTextField(wrappingLabelWithString: "")
        text.isEditable = false
        text.isSelectable = false
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byWordWrapping
        text.cell?.truncatesLastVisibleLine = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return text
    }

    private static func contentTextWidth(cardWidth: CGFloat, iconWidth: CGFloat) -> CGFloat {
        // Side padding, icon, text gap, quick-selection badge and its gap.
        max(1, cardWidth - 24 - iconWidth - 10 - 27 - 6)
    }

    private static func lineHeight(for font: NSFont?) -> CGFloat {
        let font = font ?? .systemFont(ofSize: 13)
        return max(1, ceil(font.ascender - font.descender + font.leading))
    }

    private static func thumbnailSize(contentHeight: CGFloat, width: CGFloat) -> CGFloat {
        max(56, min(144, min(contentHeight, width - 147)))
    }

    private func makeButton(_ action: ClipCardAction) -> NSButton {
        let button = ClipCardButton(title: "", target: self, action: #selector(buttonAction(_:)))
        button.tag = action.rawValue
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        configureButton(button, for: action)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func configureButton(_ button: NSButton, for action: ClipCardAction) {
        button.image = NSImage(systemSymbolName: action.symbol(for: clip, isRevealed: isRevealed),
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        let label = "\(action.title(for: clip, isRevealed: isRevealed)) (\(action.shortcut))"
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.contentTintColor = action == .favorite && clip.isFavorite ? .controlAccentColor : .secondaryLabelColor
    }

    private func metadataText() -> String {
        let calendar = Calendar.current
        let date: String
        if calendar.isDateInToday(clip.date) {
            date = Self.timeFormatter.string(from: clip.date)
        } else if calendar.isDateInYesterday(clip.date) {
            date = "Вчера, \(Self.timeFormatter.string(from: clip.date))"
        } else {
            date = Self.dateFormatter.string(from: clip.date)
        }
        let source = clip.isRemote ? "С другого устройства" : clip.source
        return source.isEmpty ? date : "\(source)   \(date)"
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.controlBackgroundColor.withAlphaComponent(selected ? 0.65 : 0.45)
            layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.08).blended(withFraction: 0.8, of: base)?.cgColor
                : base.cgColor
            layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor
                : (nearbyAnchor ? NSColor.controlAccentColor.withAlphaComponent(0.5)
                    : NSColor.separatorColor.withAlphaComponent(0.3)).cgColor
            layer?.borderWidth = selected ? 2 : (nearbyAnchor ? 1 : 0.5)
        }
    }
}

private final class ClipCardButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let card = view as? ClipCardView {
                card.rightMouseDown(with: event)
                return
            }
            ancestor = view.superview
        }
        super.rightMouseDown(with: event)
    }
}
