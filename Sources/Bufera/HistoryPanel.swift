import AppKit
import BuferaCore
import os

final class PickerWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

final class HistoryPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private static let frameName = NSWindow.FrameAutosaveName("BuferaHistory")
    let window = PickerWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 590),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    private let logger = Logger(subsystem: "local.bufera.app", category: "panel")
    private let search = NSSearchField()
    private let filters = HistoryFilters(frame: .zero)
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let thumbnails = NSCache<NSNumber, NSImage>()
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let export = NSButton(title: "Показать в Finder", target: nil, action: nil)
    private let save = NSButton(title: "Сохранить как…", target: nil, action: nil)
    private let reveal = NSButton(title: "Показать", target: nil, action: nil)
    private var revealed: (id: Int64, text: String)?
    private var revealToken = 0
    private var lastSelectedID: Int64?
    private var revealing = false
    private var confirming = false
    private var rows: [ClipSummary] = []
    private var total = 0
    private var loading = false
    private var commitWhenLoaded = false
    private var desiredIndex = 0
    private var previousApp: NSRunningApplication?
    private var suppressSelection = false
    var request: ((SearchFilter, Int) -> Void)?
    var onConfirm: ((Int64) -> Void)?
    var onReveal: ((Int64, Int) -> Void)?
    var onConceal: ((Int64) -> Void)?
    var requestThumbnail: ((Int64, @escaping (NSImage?) -> Void) -> Void)?
    var onExport: ((Int64, Bool) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onClose: (() -> Void)?
    var selected: ClipSummary? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    var isInteracting: Bool { window.isVisible && (window.isKeyWindow || filters.isPresenting || window.attachedSheet != nil) }

    override init() {
        super.init()
        build()
        thumbnails.countLimit = 150
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        window.delegate = self
        window.onKeyDown = { [weak self] event in
            guard let self, self.window.isVisible, self.window.attachedSheet == nil, !self.filters.isPresenting else { return false }
            return self.handle(event) == nil
        }
        filters.onChange = { [weak self] in self?.refresh() }
        filters.onPopoverClosed = { [weak self] in self?.closeIfUnfocused() }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: listScroll.contentView)
    }

    func open() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = frontmost }
        commitWhenLoaded = false; desiredIndex = 0; confirming = false
        invalidateReveal()
        search.isEnabled = true; search.stringValue = ""; filters.reset(); filters.setInteractionEnabled(true)
        keepOnScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(search)
        // Activation completes asynchronously when invoked by a global hotkey.
        // Reassert key status once AppKit has switched the active application.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.search)
        }
        logger.notice("Panel opened: persistent=true, visible=\(self.window.isVisible), key=\(self.window.isKeyWindow)")
        refresh()
    }

    func move(_ delta: Int) {
        guard !confirming, !commitWhenLoaded, !filters.isPresenting, window.attachedSheet == nil else { return }
        guard !rows.isEmpty else { desiredIndex = max(0, desiredIndex + delta); return }
        let index = max(0, min(rows.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
        if index >= rows.count - 10 { loadMore() }
    }

    func receive(_ result: [ClipSummary], total: Int, offset: Int) {
        loading = false; self.total = total
        if offset == 0 { rows = result } else { rows += result }
        let index = offset == 0 ? min(desiredIndex, rows.count - 1) : table.selectedRow
        suppressSelection = true
        table.reloadData()
        if index >= 0 { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        suppressSelection = false
        updateSelection()
        status.stringValue = total == 0 ? "Ничего не найдено. Скопируйте что-нибудь или измените фильтры." : "Записей: \(total.formatted())"
        if commitWhenLoaded { commitWhenLoaded = false; confirm() }
    }

    func failed(_ error: Error) {
        loading = false; commitWhenLoaded = false; confirming = false; search.isEnabled = true
        filters.setInteractionEnabled(true)
        let revealedRow = revealed.flatMap { value in rows.firstIndex(where: { $0.id == value.id }) }
        invalidateReveal()
        if let revealedRow { table.reloadData(forRowIndexes: IndexSet(integer: revealedRow), columnIndexes: IndexSet(integer: 0)) }
        updateSelection()
        status.stringValue = error.localizedDescription
    }

    func refresh() {
        guard !confirming, !commitWhenLoaded else { return }
        invalidateReveal()
        desiredIndex = 0; rows = []; table.reloadData(); updateSelection()
        loading = true; status.stringValue = "Загружаем историю…"
        request?(filter(), 0)
    }

    func close(restoreFocus: Bool = true) {
        logger.notice("Panel closed: restoreFocus=\(restoreFocus)")
        commitWhenLoaded = false; confirming = false; invalidateReveal()
        filters.dismiss()
        window.saveFrame(usingName: Self.frameName)
        window.orderOut(nil)
        onClose?()
        if restoreFocus, previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func windowDidMove(_ notification: Notification) { window.saveFrame(usingName: Self.frameName) }
    func windowDidEndLiveResize(_ notification: Notification) { window.saveFrame(usingName: Self.frameName) }
    func windowDidResignKey(_ notification: Notification) {
        closeIfUnfocused()
    }

    private func closeIfUnfocused() {
        // Filter menus, calendar popovers and save sheets can own keyboard input.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isVisible, !self.window.isKeyWindow,
                  self.window.attachedSheet == nil, !self.filters.isPresenting else { return }
            self.close(restoreFocus: false)
        }
    }

    func setSources(_ sources: [String]) { filters.setSources(sources) }
    func showConcealedText(_ text: String?, id: Int64, token: Int) {
        guard token == revealToken, window.isVisible, selected?.id == id, selected?.isConcealed == true else { return }
        revealing = false
        guard let text else { status.stringValue = "В записи нет текста для показа."; updateSelection(); return }
        revealed = (id, String(text.prefix(4_000)))
        table.reloadData(forRowIndexes: IndexSet(integer: table.selectedRow), columnIndexes: IndexSet(integer: 0))
        updateSelection()
    }

    private func invalidateReveal() { revealToken += 1; revealed = nil; revealing = false }

    private func keepOnScreen() {
        let frame = window.frame
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.contains(where: { $0.contains(frame) }) else { return }
        // Restore to the screen with the largest overlap, or the current screen
        // when the saved monitor is disconnected. Keep the title bar reachable.
        let overlapping = screens.filter { $0.intersects(frame) }.max {
            let a = $0.intersection(frame); let b = $1.intersection(frame)
            return a.width * a.height < b.width * b.height
        }
        guard let screen = overlapping ?? NSScreen.main?.visibleFrame ?? screens.first else { return }
        let size = NSSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
        let origin = NSPoint(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                             y: min(max(frame.minY, screen.minY), screen.maxY - size.height))
        window.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { close(); return nil }
        if confirming || commitWhenLoaded { return nil }
        if event.keyCode == 36 || event.keyCode == 76 { confirm(); return nil }
        if event.keyCode == 125 { move(1); return nil }
        if event.keyCode == 126 { move(-1); return nil }
        if flags.contains(.command) && event.keyCode == 3 { window.makeFirstResponder(search); return nil }
        if flags.contains([.command, .option]) {
            // Carbon consumes physical hotkeys. Handle directly delivered key events too
            // (for example accessibility input targeting this window instead of the session).
            if event.keyCode == 9 { move(1); return nil }
            if event.keyCode == 8 { move(-1); return nil }
            return event
        }
        if flags.contains(.command) && event.keyCode == 51 { deleteSelected(); return nil }
        return event
    }

    private func confirm() {
        guard !confirming, !filters.isPresenting, window.attachedSheet == nil else { return }
        if loading && rows.isEmpty {
            commitWhenLoaded = true; search.isEnabled = false; filters.setInteractionEnabled(false)
            status.stringValue = "Ожидаем историю…"; logger.notice("Confirm waiting for history")
            return
        }
        guard let selected else { close(); return }
        confirming = true; search.isEnabled = false; filters.setInteractionEnabled(false)
        status.stringValue = "Копируем в буфер…"
        logger.notice("Confirm requested")
        onConfirm?(selected.id)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, !filters.isPresenting, window.attachedSheet == nil else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
            confirm(); return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }
    @objc private func revealSelected() {
        guard let selected else { return }
        if !selected.isConcealed { onConceal?(selected.id); return }
        if revealed?.id == selected.id {
            invalidateReveal()
            table.reloadData(forRowIndexes: IndexSet(integer: table.selectedRow), columnIndexes: IndexSet(integer: 0))
            updateSelection()
        } else {
            revealToken += 1; revealing = true; updateSelection()
            onReveal?(selected.id, revealToken)
        }
    }
    @objc private func exportSelected() { if let selected { onExport?(selected.id, false) } }
    @objc private func saveSelected() { if let selected { onExport?(selected.id, true) } }
    @objc private func deleteSelected() { if let selected { onDelete?(selected.id) } }
    @objc private func clickedRow() { if table.clickedRow >= 0 { confirm() } }
    @objc private func scrolled() {
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound && visible.location + visible.length >= rows.count - 15 { loadMore() }
    }
    private func loadMore() {
        guard !loading, rows.count < total else { return }
        loading = true; request?(filter(), rows.count)
    }

    private func filter() -> SearchFilter {
        var filter = SearchFilter(); filter.query = search.stringValue
        filters.apply(to: &filter)
        return filter
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { if !suppressSelection { updateSelection() } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = rows[row]
        let cell = NSStackView(); cell.orientation = .horizontal; cell.spacing = 10
        cell.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        let icon = NSImageView(image: NSImage(systemSymbolName: clip.isConcealed ? "lock.fill" : clip.kind.symbol,
                                            accessibilityDescription: clip.isConcealed ? "Скрытая запись" : clip.kind.label) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 42).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 42).isActive = true
        if clip.kind == .image && !clip.isConcealed {
            if let cached = thumbnails.object(forKey: NSNumber(value: clip.id)) {
                icon.image = cached; icon.contentTintColor = nil
            } else {
                requestThumbnail?(clip.id) { [weak self, weak icon] image in
                    guard let image else { return }
                    self?.thumbnails.setObject(image, forKey: NSNumber(value: clip.id))
                    icon?.image = image; icon?.contentTintColor = nil
                }
            }
        }
        let shownText = clip.isConcealed ? (revealed?.id == clip.id ? revealed!.text : "••••••••") : clip.title
        let title = NSTextField(labelWithString: shownText)
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        // Hidden content must never leak through tooltips or accessibility metadata.
        title.toolTip = clip.isConcealed ? nil : (clip.text.isEmpty ? clip.title : String(clip.text.prefix(4_000)))
        if clip.isConcealed && revealed?.id != clip.id { title.setAccessibilityLabel("Скрытая запись") }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: "\(clip.date.formatted(date: .abbreviated, time: .shortened))   \(clip.source)")
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        cell.addArrangedSubview(icon); cell.addArrangedSubview(labels)
        labels.widthAnchor.constraint(equalTo: cell.widthAnchor, constant: -68).isActive = true
        title.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        return cell
    }

    private func updateSelection() {
        if lastSelectedID != selected?.id {
            let previous = revealed?.id
            invalidateReveal(); lastSelectedID = selected?.id
            if let previous, let row = rows.firstIndex(where: { $0.id == previous }) {
                table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
        let isImage = selected?.kind == .image && selected?.isConcealed == false
        export.isHidden = !isImage; save.isHidden = !isImage
        reveal.isHidden = selected == nil || (selected?.isConcealed == false && selected?.kind != .text && selected?.kind != .link)
        reveal.isEnabled = !revealing
        reveal.title = selected?.isConcealed == false ? "Скрыть" : (revealed == nil ? "Показать" : "Скрыть")
        reveal.toolTip = selected?.isConcealed == false ? "Скрыть содержимое этой записи и исключить его из поиска" : "Показать или скрыть содержимое до закрытия окна"
        reveal.image = NSImage(systemSymbolName: reveal.title == "Показать" ? "eye" : "eye.slash", accessibilityDescription: nil)
    }

    private func build() {
        window.title = "Bufera"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.level = .floating
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = false; window.backgroundColor = .clear
        let background = NSVisualEffectView(frame: window.contentView!.bounds)
        background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        window.contentView = background
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 38, left: 18, bottom: 14, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: background.leadingAnchor), root.trailingAnchor.constraint(equalTo: background.trailingAnchor), root.topAnchor.constraint(equalTo: background.topAnchor), root.bottomAnchor.constraint(equalTo: background.bottomAnchor), root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480), root.heightAnchor.constraint(greaterThanOrEqualToConstant: 380)])
        search.placeholderString = "Найти в истории"; search.delegate = self; search.font = .systemFont(ofSize: 16)
        search.sendsSearchStringImmediately = true
        search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        root.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        root.addArrangedSubview(filters)
        filters.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 60; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain; table.backgroundColor = .clear; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(clickedRow)
        table.setAccessibilityLabel("История копирований")
        listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        listScroll.contentView.postsBoundsChangedNotifications = true
        root.addArrangedSubview(listScroll)
        listScroll.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        export.target = self; export.action = #selector(exportSelected)
        save.target = self; save.action = #selector(saveSelected)
        reveal.target = self; reveal.action = #selector(revealSelected); reveal.imagePosition = .imageLeading
        export.isHidden = true; save.isHidden = true; reveal.isHidden = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, reveal, export, save]); footer.spacing = 8
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.stringValue = "⌘⌥V / C, ↑ ↓  выбор     ↩  в буфер     Esc  закрыть\n⌘F  поиск     ⌘⌫  удалить"
        root.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
    }
}
