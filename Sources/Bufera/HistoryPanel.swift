import AppKit
import BuferaCore
import os

final class PickerWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HistoryPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let window = PickerWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 590),
                              styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    private let logger = Logger(subsystem: "local.bufera.app", category: "panel")
    private let search = NSSearchField()
    private let kinds = NSPopUpButton()
    private let dates = NSPopUpButton()
    private let from = NSDatePicker()
    private let until = NSDatePicker()
    private let dateRange = NSStackView()
    private let table = NSTableView()
    private let listScroll = NSScrollView()
    private let preview = NSTextView()
    private let previewImage = NSImageView()
    private let metadata = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let export = NSButton(title: "Показать в Finder", target: nil, action: nil)
    private let save = NSButton(title: "Сохранить как…", target: nil, action: nil)
    private var eventMonitor: Any?
    private var rows: [ClipSummary] = []
    private var total = 0
    private var loading = false
    private var commitWhenLoaded = false
    private var desiredIndex = 0
    private var previousApp: NSRunningApplication?
    private var suppressSelection = false
    var request: ((SearchFilter, Int) -> Void)?
    var onConfirm: ((Int64) -> Void)?
    var onSelection: ((ClipSummary) -> Void)?
    var onExport: ((Int64, Bool) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onClose: (() -> Void)?
    var selected: ClipSummary? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    var isInteracting: Bool { window.isVisible && window.isKeyWindow }

    override init() {
        super.init()
        build()
        window.delegate = self
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isVisible, event.window === self.window else { return event }
            return self.handle(event)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: listScroll.contentView)
    }

    func open(activateApplication: Bool = true) {
        previousApp = NSWorkspace.shared.frontmostApplication
        commitWhenLoaded = false; desiredIndex = 0
        search.stringValue = ""; kinds.selectItem(at: 0); dates.selectItem(at: 0); dateRange.isHidden = true
        window.center()
        if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 420, y: screen.visibleFrame.midY - 235)) }
        if activateApplication { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(search)
        logger.notice("Panel opened: persistent=true, visible=\(self.window.isVisible), key=\(self.window.isKeyWindow)")
        refresh()
    }

    func move(_ delta: Int) {
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
        loading = false; commitWhenLoaded = false
        status.stringValue = error.localizedDescription
    }

    func refresh() {
        desiredIndex = 0; rows = []; table.reloadData(); updateSelection()
        loading = true; status.stringValue = "Загружаем историю…"
        request?(filter(), 0)
    }

    func setImage(_ image: NSImage?, id: Int64) {
        guard selected?.id == id else { return }
        previewImage.image = image
    }

    func close(restoreFocus: Bool = true) {
        logger.notice("Panel closed: restoreFocus=\(restoreFocus)")
        commitWhenLoaded = false
        window.orderOut(nil)
        onClose?()
        if restoreFocus, previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp?.activate(options: [])
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func windowDidResignKey(_ notification: Notification) {
        // Native save sheets intentionally take key status from their parent.
        if window.attachedSheet == nil && window.isVisible { close(restoreFocus: false) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { close(); return nil }
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
        if loading && rows.isEmpty { commitWhenLoaded = true; return }
        guard let selected else { close(); return }
        onConfirm?(selected.id)
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }
    @objc private func filterChanged() { dateRange.isHidden = dates.indexOfSelectedItem != 4; refresh() }
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
        if kinds.indexOfSelectedItem > 0 { filter.kind = ClipKind.allCases[kinds.indexOfSelectedItem - 1] }
        let calendar = Calendar.current; let today = calendar.startOfDay(for: Date())
        switch dates.indexOfSelectedItem {
        case 1: filter.from = today
        case 2: filter.from = calendar.date(byAdding: .day, value: -1, to: today); filter.until = today
        case 3: filter.from = calendar.date(byAdding: .day, value: -6, to: today)
        case 4:
            filter.from = calendar.startOfDay(for: min(from.dateValue, until.dateValue))
            filter.until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from.dateValue, until.dateValue)))
        default: break
        }
        return filter
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { if !suppressSelection { updateSelection() } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let clip = rows[row]
        let cell = NSStackView(); cell.orientation = .horizontal; cell.spacing = 10
        cell.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        let icon = NSImageView(image: NSImage(systemSymbolName: clip.kind.symbol, accessibilityDescription: clip.kind.label) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let title = NSTextField(labelWithString: clip.title)
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = NSTextField(labelWithString: "\(clip.date.formatted(date: .abbreviated, time: .shortened))   \(clip.source)")
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        cell.addArrangedSubview(icon); cell.addArrangedSubview(labels)
        return cell
    }

    private func updateSelection() {
        previewImage.image = nil
        guard let clip = selected else {
            preview.string = "Здесь появится содержимое выбранной записи.\n\nBufera запоминает новые копирования, пока приложение запущено."
            metadata.stringValue = "История буфера обмена"; previewImage.isHidden = true
            export.isHidden = true; save.isHidden = true; return
        }
        preview.string = clip.text.isEmpty ? (clip.kind == .image ? "" : clip.title) : clip.text
        metadata.stringValue = "\(clip.kind.label)\n\(clip.date.formatted(date: .complete, time: .standard))\n\(clip.source)  •  \(ByteCountFormatter.string(fromByteCount: Int64(clip.byteCount), countStyle: .file))"
        previewImage.isHidden = clip.kind != .image
        export.isHidden = clip.kind != .image; save.isHidden = clip.kind != .image
        onSelection?(clip)
    }

    private func build() {
        window.title = "Bufera"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.backgroundColor = .windowBackgroundColor
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 38, left: 18, bottom: 14, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        search.placeholderString = "Найти в истории"; search.delegate = self; search.font = .systemFont(ofSize: 16)
        search.sendsSearchStringImmediately = true
        search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        root.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        kinds.addItems(withTitles: ["Все типы"] + ClipKind.allCases.map(\.label))
        dates.addItems(withTitles: ["За всё время", "Сегодня", "Вчера", "Последние 7 дней", "Период…"])
        for popup in [kinds, dates] { popup.target = self; popup.action = #selector(filterChanged) }
        let filters = NSStackView(views: [kinds, dates]); filters.spacing = 8
        root.addArrangedSubview(filters)
        for picker in [from, until] {
            picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = .yearMonthDay
            picker.dateValue = Date(); picker.target = self; picker.action = #selector(filterChanged)
        }
        dateRange.addArrangedSubview(NSTextField(labelWithString: "С")); dateRange.addArrangedSubview(from)
        dateRange.addArrangedSubview(NSTextField(labelWithString: "по")); dateRange.addArrangedSubview(until)
        dateRange.spacing = 8; dateRange.isHidden = true; root.addArrangedSubview(dateRange)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip")))
        table.headerView = nil; table.rowHeight = 60; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain; table.backgroundColor = .clear; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(clickedRow)
        table.setAccessibilityLabel("История копирований")
        listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        listScroll.contentView.postsBoundsChangedNotifications = true
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        preview.isEditable = false; preview.isSelectable = true; preview.drawsBackground = false
        preview.font = .systemFont(ofSize: 13); preview.textContainerInset = NSSize(width: 2, height: 6)
        preview.isHorizontallyResizable = false; preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        let previewScroll = NSScrollView(); previewScroll.documentView = preview; previewScroll.hasVerticalScroller = true; previewScroll.drawsBackground = false
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.heightAnchor.constraint(equalToConstant: 180).isActive = true
        metadata.font = .systemFont(ofSize: 11); metadata.textColor = .secondaryLabelColor
        metadata.setContentCompressionResistancePriority(.required, for: .vertical)
        export.target = self; export.action = #selector(exportSelected)
        save.target = self; save.action = #selector(saveSelected)
        let actions = NSStackView(views: [export, save]); actions.orientation = .vertical; actions.alignment = .leading; actions.spacing = 6
        let right = NSStackView(views: [metadata, previewImage, previewScroll, actions])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 12
        right.widthAnchor.constraint(equalToConstant: 290).isActive = true
        for view in [metadata, previewImage, previewScroll] { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        let body = NSStackView(views: [listScroll, divider, right]); body.orientation = .horizontal; body.alignment = .top; body.spacing = 14
        root.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 290).isActive = true
        for view in [listScroll, divider, right] { view.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.stringValue = "⌘⌥V / C, ↑ ↓  выбор     ↩  в буфер     Esc  закрыть     ⌘F  поиск     ⌘⌫  удалить"
        root.addArrangedSubview(status); root.addArrangedSubview(hint)
        status.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
    }
}
