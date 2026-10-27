import BufferaLocalization
import AppKit
import BufferaCore
import os

final class PickerWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    var permitsOffscreenFrame = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        permitsOffscreenFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged { onFlagsChanged?(event.modifierFlags) }
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

final class HistoryPanel: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    private static let frameName = NSWindow.FrameAutosaveName("BufferaHistory")
    let window = PickerWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 590),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    private let logger = Logger(subsystem: "local.buffera.app", category: "panel")
    private let search = NSSearchField()
    private let semanticSearch = NSButton(checkboxWithTitle: L10n.text("Искать также по смыслу"), target: nil, action: nil)
    private let chatButton = HistoryAskButton(title: L10n.text("Спросить"))
    private let semanticSetup = NSButton(title: L10n.text("Поиск по смыслу · выключен — настроить"), target: nil, action: nil)
    private let searchOptionsRow = NSStackView()
    private var semanticSearchAvailable = false
    private var chatAvailable = false
    private var actualSearchMode: ActualSearchMode = .literal
    private var searchFallbackReason: String?
    private let filters = HistoryFilters(frame: .zero)
    private let cards = HistoryCardsView()
    private var appearance = HistoryAppearance.load()
    private let sidebarButton = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L10n.text("Боковое меню"))!, target: nil, action: nil)
    private let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.text("Настройки"))!, target: nil, action: nil)
    private let contentRow = NSStackView()
    private var sidebarWidth: NSLayoutConstraint!
    private var bodyMinimumHeight: NSLayoutConstraint!
    private var presentationToken = 0
    private var focusToken = 0
    private var outsideInteractionToken = 0
    private let currentFrontmostApplication: () -> NSRunningApplication?
    private var changingFrame = false
    private var isClosing = false
    private let thumbnails = NSCache<NSNumber, NSImage>()
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let pinButton = NSButton(image: NSImage(systemSymbolName: "pin", accessibilityDescription: nil)!, target: nil, action: nil)
    private let scope = NSSegmentedControl(labels: [L10n.text("История"), L10n.text("Избранное")], trackingMode: .selectOne, target: nil, action: nil)
    private let nearbyBack = NSButton(title: L10n.text("Назад в историю"), target: nil, action: nil)
    private let nearbyHeading = NSTextField(wrappingLabelWithString: "")
    private let nearbyHeader = NSStackView()
    private let introductionDefaults: UserDefaults
    private var nearbyIntroduction: NearbyIntroductionWindow?
    private var nearbyState: NearbyHistoryState?
    private var nearbyToken = 0
    private var pendingViewport: NSPoint?
    private let resetSearch = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: L10n.text("Вся история"))!, target: nil, action: nil)
    private let preview = ClipPreview()
    private var copyTransformSourceID: Int64?
    private var copyTransformToken = 0
    private var copyTransformHistoryDirty = false
    private var copyOptionsID: Int64?
    private var copyOptions: [CopyTransformOperation]?
    private var copyOptionsToken = 0
    private var previewToken = 0
    private var previewRequestPending = false
    private var commandHeld = false
    private var shortcuts = ShortcutPreferences.defaults
    private var shortcutGesture = HistoryShortcutGesture()

    func applyShortcuts(_ value: ShortcutPreferences) {
        cancelShortcutGesture()
        shortcuts = value
        shortcutGesture.requiredModifiers = value.base.modifiers
    }
    private var shortcutModifiersTimer: Timer?
    private var cardMenuTracking = false
    private var dragSourceID: Int64?
    private var dragHistoryDirty = false
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var cancelDragPreparation: (() -> Void)?
    private var pendingSelectionID: Int64?
    private var retainedSelectionID: Int64?
    private var retainedRowCount = 150
    private let resetDefaults: UserDefaults
    private let currentDate: () -> Date
    private var closedAt: Date?
    private var recentCaptureID: Int64?
    private var pendingFavorites: Set<Int64> = []
    private var revealed: (id: Int64, text: String)?
    private var revealToken = 0
    private var lastSelectedID: Int64?
    private var revealing = false
    private var confirming = false
    private var rows: [ClipSummary] = []
    private var total = 0
    private var loading = false
    private var searchIndexDirty = false
    private var searchIndexTimer: Timer?
    private var silentSearchRefresh = false
    private var commitWhenLoaded = false
    private var pendingMoveDelta = 0
    private var previousApp: NSRunningApplication?
    private var appActivationObserver: NSObjectProtocol?
    var request: ((SearchFilter, Int, Int) -> Void)?
    var requestNearby: ((Int64, Int) -> Void)?
    var onNavigate: (() -> Void)?
    var onConfirm: ((Int64) -> Void)?
    var requestDragPayload: ((Int64, @escaping (Result<ClipDragPayload, Error>) -> Void) -> Void)?
    var onDragCompleted: ((Int64) -> Void)?
    var onReveal: ((Int64, Int) -> Void)?
    var onConceal: ((Int64) -> Void)?
    var requestThumbnail: ((Int64, @escaping (NSImage?) -> Void) -> Void)?
    var onExport: ((Int64, Bool) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onFavorite: ((Int64, Bool) -> Void)?
    var onPreview: ((ClipSummary, Int) -> Void)?
    var requestCopyTransformOperations: ((Int64, @escaping (Result<[CopyTransformOperation], Error>) -> Void) -> Void)?
    var requestCopyTransform: ((Int64, CopyTransformOperation, @escaping (Result<String, Error>) -> Void) -> Void)?
    var onCopyTransformed: ((Int64, CopyTransformOperation, String, @escaping (Error?) -> Void) -> Void)?
    var onCancelCopyTransformed: (() -> Void)?
    var onClose: (() -> Void)?
    var onShortcutGestureEnd: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowFeatures: (() -> Void)?
    var onShowChat: (() -> Void)?
    var onAppearanceChange: ((HistoryAppearance) -> Void)?
    var selected: ClipSummary? { rows.indices.contains(cards.selectedIndex) ? rows[cards.selectedIndex] : nil }
    var isConfirmingCopyTransform: Bool { copyTransformSourceID != nil && confirming }
    var isRefreshingSearchIndex: Bool { silentSearchRefresh }
    var isShowingNearby: Bool { nearbyState != nil }
    var isPinned: Bool { pinButton.state == .on }
    var searchMode: HistorySearchMode { semanticSearchAvailable && semanticSearch.state == .on ? .automatic : .literal }
    var isInteracting: Bool { window.isVisible && !isClosing && (dragSourceID != nil || window.isKeyWindow || nearbyIntroduction != nil || filters.isPresenting || cardMenuTracking || preview.isShown || window.attachedSheet != nil) }
    var isAvailableForShortcut: Bool { window.isVisible && !isClosing && nearbyIntroduction == nil }

    init(introductionDefaults: UserDefaults = .standard, monitorsOutsideInteractions: Bool = true,
         resetDefaults: UserDefaults = .standard, currentDate: @escaping () -> Date = Date.init,
         currentFrontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.introductionDefaults = introductionDefaults
        self.resetDefaults = resetDefaults
        self.currentDate = currentDate
        self.currentFrontmostApplication = currentFrontmostApplication
        super.init()
        build()
        thumbnails.countLimit = 150
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.delegate = self
        window.onKeyDown = { [weak self] event in
            if let self, self.dragSourceID != nil {
                if event.keyCode == 53 {
                    self.cancelDragPreparation?()
                    // Active native drags handle Escape themselves. A cancelled
                    // preparation consumes it so it cannot also close the panel.
                    return self.dragSourceID == nil
                }
                return true
            }
            guard let self, self.window.isVisible, self.window.attachedSheet == nil,
                  !self.isClosing, self.nearbyIntroduction == nil, !self.filters.isPresenting, !self.cardMenuTracking else { return false }
            return self.handle(event) == nil
        }
        window.onFlagsChanged = { [weak self] flags in
            self?.modifiersChanged(flags)
        }
        filters.onChange = { [weak self] in self?.refresh() }
        filters.onPopoverClosed = { [weak self] in self?.closeIfUnfocused() }
        preview.onClose = { [weak self] in
            self?.commandHeld = NSEvent.modifierFlags.contains(.command)
            self?.updateVisibleCards(); self?.closeIfUnfocused()
        }
        preview.onConfirm = { [weak self] in self?.confirm() }
        preview.onMove = { [weak self] delta in self?.move(delta) }
        cards.makeCard = { [unowned self] index in self.makeCard(at: index) }
        cards.heightForCard = { [weak self] index, width, maximumHeight in
            guard let self, self.rows.indices.contains(index) else { return maximumHeight }
            let clip = self.rows[index]
            return ClipCardView.preferredHeight(for: clip,
                revealedText: self.revealed?.id == clip.id ? self.revealed?.text : nil,
                width: width, maximumHeight: maximumHeight)
        }
        cards.onSelect = { [weak self] _ in self?.updateSelection() }
        cards.onActivate = { [weak self] _ in self?.confirm() }
        cards.onNeedMore = { [weak self] in self?.loadMore() }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive),
                                               name: NSApplication.didResignActiveNotification, object: NSApp)
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, monitorsOutsideInteractions,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.applicationDidActivate(app)
        }
        if monitorsOutsideInteractions {
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
                self?.observeMouseDown(event, source: .globalMouse)
            }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                self?.observeMouseDown(event, source: .localMouse)
                return event
            }
        }
        configureAppearance()
        if appearance.mode != .floating { positionDockedWindow() }
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver) }
    }

    /// Returns whether the previous navigation state expired while closed.
    @discardableResult
    func open(fromShortcut: Bool = false) -> Bool {
        if let nearbyIntroduction { nearbyIntroduction.show(); return false }
        cancelCopyTransform(refreshHistory: false)
        cancelShortcutGesture()
        rememberPreviousApp()
        presentationToken += 1; isClosing = false
        window.permitsOffscreenFrame = false
        let token = presentationToken
        commitWhenLoaded = false; pendingMoveDelta = 0; confirming = false
        let reset = HistoryResetPreferences.load(from: resetDefaults).shouldReset(closedAt: closedAt, now: currentDate())
        closedAt = nil
        if reset { resetNavigationState() }
        invalidateReveal()
        updateNavigationControls()
        commandHeld = false
        if appearance.mode == .floating { keepOnScreen() }
        else { positionDockedWindow() }
        focusHistoryWindow(token: token)
        logger.notice("Panel opened: persistent=true, visible=\(self.window.isVisible), key=\(self.window.isKeyWindow)")
        refresh(preservingSelection: !reset)
        if fromShortcut { recordShortcutPress() }
        return reset
    }

    private func rememberPreviousApp() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = frontmost }
    }

    private func focusHistoryWindow(token: Int) {
        focusToken += 1
        let focus = focusToken
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(cards)
        // Activation completes asynchronously when invoked by a global hotkey.
        // Reassert key status once AppKit has switched the active application.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isVisible, token == self.presentationToken, focus == self.focusToken, !self.isClosing,
                  self.window.attachedSheet == nil else { return }
            self.window.makeKeyAndOrderFront(nil)
            self.window.makeFirstResponder(self.cards)
        }
    }

    func shortcutPressed(_ delta: Int, isRepeat: Bool = false, fromGlobalShortcut: Bool = false) {
        guard !isRepeat, isAvailableForShortcut, !confirming, !commitWhenLoaded,
              !filters.isPresenting, !cardMenuTracking, window.attachedSheet == nil else { return }
        // A visible panel may never have received focus after app activation.
        // Recover focus before interpreting another global press as navigation.
        if !window.isKeyWindow, fromGlobalShortcut || (isPinned && !shortcutGesture.isActive) {
            cancelShortcutGesture()
            rememberPreviousApp()
            presentationToken += 1
            focusHistoryWindow(token: presentationToken)
            return
        }
        // Only the hold that opened this presentation can enable quick selection.
        // Once released, later shortcuts navigate the persistent window.
        if shortcutGesture.isActive { recordShortcutPress() }
        move(delta)
    }

    private func recordShortcutPress() {
        shortcutGesture.press()
        guard shortcutModifiersTimer == nil else { return }
        // A quick first tap can release its modifiers before the panel becomes
        // key and receives flagsChanged. Observe the current flags only during a gesture.
        let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.modifiersChanged(NSEvent.modifierFlags)
        }
        shortcutModifiersTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.command)
        if commandHeld != held { commandHeld = held; updateVisibleCards() }
        let wasActive = shortcutGesture.isActive
        let shouldConfirm = shortcutGesture.modifiersChanged(flags)
        if wasActive && !shortcutGesture.isActive {
            shortcutModifiersTimer?.invalidate(); shortcutModifiersTimer = nil
            onShortcutGestureEnd?()
        }
        if shouldConfirm, isAvailableForShortcut { confirm() }
    }

    private func cancelShortcutGesture() {
        let wasActive = shortcutGesture.isActive
        shortcutGesture.cancel()
        shortcutModifiersTimer?.invalidate(); shortcutModifiersTimer = nil
        if wasActive { onShortcutGestureEnd?() }
    }

    func move(_ delta: Int) {
        guard !isClosing, !confirming, !commitWhenLoaded, !filters.isPresenting, !cardMenuTracking, window.attachedSheet == nil else { return }
        if preview.isShown { dismissPreview(); window.makeKey() }
        window.makeFirstResponder(cards)
        guard !rows.isEmpty else { pendingMoveDelta += delta; return }
        let index = max(0, min(rows.count - 1, cards.selectedIndex + delta))
        cards.select(index, scrollIntoView: true)
        updateSelection()
        if index >= rows.count - 10 { loadMore() }
    }

    func receive(_ result: [ClipSummary], total: Int, offset: Int) {
        if dragSourceID != nil { dragHistoryDirty = true; return }
        if isConfirmingCopyTransform { copyTransformHistoryDirty = true; return }
        guard isAvailableForShortcut, !isShowingNearby else { return }
        if offset == 0, silentSearchRefresh {
            receiveSearchIndexResult(result, total: total)
            return
        }
        if offset == 0, let id = pendingSelectionID,
           !result.contains(where: { $0.id == id || $0.id == recentCaptureID }),
           result.count < total, let request {
            // A retained choice may be beyond the first page, or displaced by
            // new matches. Resolve it before replacing the list or applying keys.
            request(filter(), 0, min(total, max(result.count + 150, result.count * 2)))
            return
        }
        loading = false; self.total = total
        if offset == 0 { rows = result } else { rows += result }
        let capturedIndex = recentCaptureID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
        let retainedIndex = capturedIndex ?? pendingSelectionID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
        let restoredIndex = rows.isEmpty ? -1 : max(0, min(rows.count - 1, (retainedIndex ?? 0) + pendingMoveDelta))
        let index = offset == 0 ? restoredIndex : cards.selectedIndex
        if offset == 0 { pendingSelectionID = nil; pendingMoveDelta = 0; recentCaptureID = nil }
        cards.reload(count: rows.count, selectedIndex: index, scrollToSelection: offset == 0 && pendingViewport == nil)
        if offset == 0, let viewport = pendingViewport {
            pendingViewport = nil
            cards.restoreScrollPosition(viewport)
        }
        updateSelection()
        updateCount()
        if commitWhenLoaded { commitWhenLoaded = false; confirm() }
    }

    /// Called only after an external copy has committed to history. A filtered
    /// view keeps its previous choice when the new record does not match it.
    func clipboardDidCapture(id: Int64) {
        if dragSourceID != nil { dragHistoryDirty = true; return }
        if isConfirmingCopyTransform {
            copyTransformHistoryDirty = true
            if isShowingNearby { nearbyState?.needsReload = true }
            return
        }
        if isShowingNearby { nearbyState?.needsReload = true; return }
        recentCaptureID = id
        guard isAvailableForShortcut, !confirming, !commitWhenLoaded else { return }
        let moves = pendingMoveDelta
        refresh(preservingSelection: true)
        pendingMoveDelta = moves
    }

    func closeAfterConfirmation() {
        // Confirmation supersedes copies received while its payload was loading.
        recentCaptureID = nil
        close()
    }

    private func requestShowNearby(id: Int64) {
        guard isAvailableForShortcut, !loading, !confirming, !commitWhenLoaded,
              pendingFavorites.isEmpty, window.attachedSheet == nil else { return }
        if introductionDefaults.bool(forKey: NearbyIntroductionWindow.preferenceKey) { showNearby(id: id) }
        else { presentNearbyIntroduction(anchorID: id) }
    }

    @objc private func explainNearby() { presentNearbyIntroduction(anchorID: nil) }

    private func presentNearbyIntroduction(anchorID: Int64?) {
        guard nearbyIntroduction == nil else { nearbyIntroduction?.show(); return }
        cancelShortcutGesture(); dismissPreview(); remaskConcealedText()
        let controller = NearbyIntroductionWindow(explainingOnly: anchorID == nil, defaults: introductionDefaults)
        nearbyIntroduction = controller
        controller.onDismiss = { [weak self] accepted in
            guard let self else { return }
            self.nearbyIntroduction = nil
            if NSApp.isActive { self.window.makeKeyAndOrderFront(nil) }
            if accepted, let anchorID { self.showNearby(id: anchorID) }
        }
        controller.show()
    }

    @objc private func setupSemanticSearch() {
        guard !isClosing, !confirming, !commitWhenLoaded, nearbyIntroduction == nil else { return }
        dismissPreview(); filters.dismiss()
        onShowFeatures?()
    }

    func updateSemanticPreparation(_ status: String?) {
        semanticSearch.title = status.map { L10n.text("По смыслу · \($0)") } ?? L10n.text("Искать также по смыслу")
        semanticSearch.setAccessibilityLabel(semanticSearch.title)
    }

    func updateSemanticSetup(title: String, detail: String? = nil) {
        semanticSetup.title = title
        semanticSetup.toolTip = detail ?? title
    }

    func showNearby(id: Int64) {
        guard isAvailableForShortcut, !loading, !confirming, !commitWhenLoaded,
              pendingFavorites.isEmpty, window.attachedSheet == nil,
              let clip = rows.first(where: { $0.id == id }) else { return }
        if nearbyState == nil {
            let returnPoint = NearbyHistoryState.ReturnPoint(rows: rows, total: total,
                selectedID: selected?.id, viewport: cards.scrollView.contentView.bounds.origin)
            nearbyState = NearbyHistoryState(returnPoint: returnPoint, anchorID: id, anchorDate: clip.date)
        }
        loadNearby(anchorID: id, date: clip.date)
    }

    /// A chat source can be outside the current search page. Opening it only
    /// navigates; clipboard confirmation remains an explicit separate action.
    func openSource(_ clip: ClipSummary) {
        guard !clip.isConcealed, window.attachedSheet == nil else { return }
        var returnPoint = NearbyHistoryState.ReturnPoint(rows: [], total: total,
            selectedID: selected?.id ?? pendingSelectionID ?? retainedSelectionID,
            viewport: cards.scrollView.contentView.bounds.origin)
        if open() {
            returnPoint = NearbyHistoryState.ReturnPoint(rows: [], total: 0, selectedID: nil, viewport: .zero)
        }
        // Source navigation starts in Buffera's chat, not the older external
        // application remembered by a previous global-hotkey presentation.
        previousApp = .current
        if nearbyState == nil {
            nearbyState = NearbyHistoryState(returnPoint: returnPoint, anchorID: clip.id, anchorDate: clip.date)
        }
        nearbyState?.needsReload = true
        loadNearby(anchorID: clip.id, date: clip.date)
    }

    private func loadNearby(anchorID: Int64, date: Date, preservingSelection: Bool = false) {
        guard nearbyState != nil else { return }
        cancelShortcutGesture(); cancelSearchIndexRefresh(); dismissPreview(); invalidateReveal()
        nearbyToken += 1
        onNavigate?()
        nearbyState?.anchorID = anchorID; nearbyState?.anchorDate = date
        pendingSelectionID = preservingSelection ? selected?.id : nil
        pendingViewport = nil; pendingMoveDelta = 0; recentCaptureID = nil
        loading = true; rows = []; total = 0
        cards.replace(count: 0, selectedIndex: -1)
        updateNavigationControls(); updateSelection()
        status.stringValue = L10n.text("Загружаем соседние записи…")
        status.toolTip = nearbyState?.title
        window.makeFirstResponder(cards)
        requestNearby?(anchorID, nearbyToken)
    }

    func receiveNearby(_ result: [ClipSummary], anchorID: Int64, token: Int) {
        guard window.isVisible, !isClosing, token == nearbyToken, nearbyState?.anchorID == anchorID else { return }
        guard let anchor = result.first(where: { $0.id == anchorID }) else {
            nearbyFailed(HistoryError.missing, token: token); return
        }
        nearbyState?.anchorDate = anchor.date
        rows = result; total = result.count; loading = false
        let base = result.firstIndex(where: { $0.id == pendingSelectionID })
            ?? result.firstIndex(where: { $0.id == anchorID }) ?? 0
        let index = max(0, min(result.count - 1, base + pendingMoveDelta))
        pendingSelectionID = nil; pendingMoveDelta = 0
        cards.replace(count: rows.count, selectedIndex: index)
        cards.scrollToSelection(centered: true)
        updateSelection(); updateCount()
        if commitWhenLoaded { commitWhenLoaded = false; confirm() }
    }

    func nearbyFailed(_ error: Error, token: Int) {
        guard window.isVisible, !isClosing, isShowingNearby, token == nearbyToken else { return }
        failed(error)
    }

    @objc func returnFromNearby() {
        restoreSearchFromNearby(reloadIfNeeded: true)
    }

    private func restoreSearchFromNearby(reloadIfNeeded: Bool, render: Bool = true) {
        guard let context = nearbyState else { return }
        cancelShortcutGesture(); cancelSearchIndexRefresh(); dismissPreview(); invalidateReveal()
        nearbyToken += 1; onNavigate?()
        nearbyState = nil
        loading = false; confirming = false; commitWhenLoaded = false
        pendingSelectionID = nil; pendingMoveDelta = 0; pendingViewport = nil; recentCaptureID = nil
        retainedSelectionID = context.returnPoint.selectedID
        retainedRowCount = max(150, context.returnPoint.rows.count)
        let needsFreshRows = reloadIfNeeded && context.needsReload
        // A mutation may have concealed or deleted a saved row. Never redraw
        // that old snapshot while returning or during the panel's close animation.
        rows = render && !needsFreshRows ? context.returnPoint.rows : []
        total = context.returnPoint.total
        let index = rows.firstIndex(where: { $0.id == context.returnPoint.selectedID }) ?? (rows.isEmpty ? -1 : 0)
        updateNavigationControls()
        cards.replace(count: rows.count, selectedIndex: index)
        cards.restoreScrollPosition(context.returnPoint.viewport)
        updateSelection(); updateCount()
        window.makeFirstResponder(cards)
        if needsFreshRows {
            refresh(preservingSelection: true)
            pendingViewport = context.returnPoint.viewport
        }
    }

    private func updateNavigationControls() {
        let enabled = !isShowingNearby && !confirming && !commitWhenLoaded
        search.isEnabled = enabled; semanticSearch.isEnabled = enabled && semanticSearchAvailable; filters.setInteractionEnabled(enabled); scope.isEnabled = enabled
        semanticSearch.isHidden = isShowingNearby || !semanticSearchAvailable
        chatButton.isHidden = !chatAvailable
        chatButton.isEnabled = chatAvailable && !confirming && !commitWhenLoaded
        semanticSetup.isHidden = isShowingNearby || semanticSearchAvailable
        semanticSetup.isEnabled = enabled
        searchOptionsRow.isHidden = semanticSearch.isHidden && semanticSetup.isHidden && chatButton.isHidden
        nearbyHeader.isHidden = !isShowingNearby
        nearbyBack.title = search.stringValue.isEmpty && !filters.hasActiveFilters && scope.selectedSegment == 0
            ? L10n.text("К истории") : L10n.text("К результатам поиска")
        nearbyBack.setAccessibilityLabel(nearbyBack.title)
        if let context = nearbyState {
            nearbyHeading.stringValue = L10n.text("Копирования до и после") + "\n" +
                L10n.text("Из всей истории · \(context.anchorDate.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(L10n.locale)))")
        }
        scope.isHidden = isShowingNearby; nearbyBack.isHidden = !isShowingNearby
        nearbyBack.isEnabled = !confirming && !commitWhenLoaded
        resetSearch.isHidden = isShowingNearby || (search.stringValue.isEmpty && !filters.hasActiveFilters && scope.selectedSegment == 0)
        search.toolTip = isShowingNearby ? L10n.text("Показаны соседние копирования из всей истории. Esc — закрыть окно.") : nil
        hint.stringValue = isShowingNearby
            ? L10n.text("Esc закрыть   ↑↓ выбор   ↩ в буфер   Пробел просмотр")
            : L10n.text("↑↓ выбор   ↩ в буфер   Пробел просмотр   ⌘D избранное")
    }

    func updateFeatureAvailability(semanticSearch: Bool, chat: Bool) {
        let previousMode = searchMode
        semanticSearchAvailable = semanticSearch
        chatAvailable = chat
        updateNavigationControls()
        // Keep the checkbox preference, but never request semantic search while unavailable.
        if previousMode != searchMode { searchIndexDidChange() }
    }

    func updateSearchMode(_ actual: ActualSearchMode, reason: String?) {
        actualSearchMode = actual
        searchFallbackReason = reason
        semanticSearch.toolTip = reason ?? (searchMode == .literal
            ? L10n.text("Все слова запроса должны встретиться в записи.")
            : L10n.text("По словам и по смыслу, когда «Поиск по смыслу» включён в настройках. Пустой запрос показывает историю."))
    }

    /// OCR and embeddings update the search index without changing a card's displayed content.
    func searchIndexDidChange() {
        if selected?.kind == .image {
            copyOptionsToken += 1; copyOptionsID = nil; copyOptions = nil
            updateVisibleCards()
        }
        if isConfirmingCopyTransform {
            copyTransformHistoryDirty = true
            if isShowingNearby { nearbyState?.needsReload = true }
            return
        }
        if isShowingNearby { nearbyState?.needsReload = true; return }
        guard canRefreshSearchIndex else { return }
        searchIndexDirty = true
        // Coalesce a burst without postponing its first refresh indefinitely
        // when a backlog keeps producing OCR completions.
        scheduleSearchIndexRefresh(after: 0.6)
    }

    func searchFailed(_ error: Error) {
        if isConfirmingCopyTransform { copyTransformHistoryDirty = true; return }
        guard !isShowingNearby else { return }
        guard silentSearchRefresh else { failed(error); return }
        silentSearchRefresh = false
        loading = false
        if commitWhenLoaded && rows.isEmpty { failed(error) }
        // A background refresh must not reset an interaction started while the
        // query was running. The application still reports the storage error.
        if searchIndexDirty { scheduleSearchIndexRefresh(after: 0.8) }
    }

    func failed(_ error: Error) {
        cancelShortcutGesture()
        loading = false; commitWhenLoaded = false; confirming = false
        updateNavigationControls()
        let revealedRow = revealed.flatMap { value in rows.firstIndex(where: { $0.id == value.id }) }
        invalidateReveal()
        if let revealedRow { cards.reloadCard(at: revealedRow) }
        updateSelection()
        status.stringValue = error.localizedDescription
    }

    func refresh(preservingSelection: Bool = false) {
        guard !isClosing, !confirming, !commitWhenLoaded else { return }
        if let context = nearbyState {
            nearbyState?.needsReload = true
            loadNearby(anchorID: context.anchorID, date: context.anchorDate, preservingSelection: preservingSelection)
            return
        }
        pendingViewport = nil
        cancelSearchIndexRefresh()
        pendingSelectionID = preservingSelection ? (selected?.id ?? pendingSelectionID ?? retainedSelectionID) : nil
        let limit = preservingSelection ? max(150, rows.count, retainedRowCount) : 150
        dismissPreview()
        invalidateReveal()
        loading = true
        actualSearchMode = .literal; searchFallbackReason = nil
        pendingMoveDelta = 0; rows = []; cards.reload(count: 0, selectedIndex: -1, scrollToSelection: false); updateSelection()
        status.stringValue = L10n.text("Загружаем историю…")
        resetSearch.isHidden = search.stringValue.isEmpty && !filters.hasActiveFilters && scope.selectedSegment == 0
        request?(filter(), 0, limit)
    }

    func close(restoreFocus: Bool = true) {
        nearbyIntroduction?.onDismiss = nil
        nearbyIntroduction?.close(); nearbyIntroduction = nil
        if dragSourceID != nil {
            cancelDragPreparation?()
            if dragSourceID != nil { return }
        }
        cancelShortcutGesture()
        guard !isClosing else { return }
        if window.isVisible { closedAt = currentDate() }
        cancelCopyTransform(refreshHistory: false)
        copyOptionsToken += 1; copyOptionsID = nil; copyOptions = nil
        restoreSearchFromNearby(reloadIfNeeded: false, render: false)
        cancelSearchIndexRefresh()
        logger.notice("Panel closed: restoreFocus=\(restoreFocus)")
        retainedSelectionID = selected?.id ?? pendingSelectionID ?? retainedSelectionID
        if !rows.isEmpty { retainedRowCount = rows.count }
        presentationToken += 1; let token = presentationToken; isClosing = true
        dismissPreview(); commandHeld = false
        commitWhenLoaded = false; confirming = false; invalidateReveal()
        filters.dismiss(); saveFloatingFrame()
        onClose?()
        let finish = { [weak self] in
            guard let self, self.presentationToken == token else { return }
            self.window.orderOut(nil); self.window.permitsOffscreenFrame = false; self.isClosing = false
            if restoreFocus, self.previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.previousApp?.activate(options: [])
            }
        }
        if appearance.mode != .floating && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.permitsOffscreenFrame = true
            let hidden = hiddenFrame(for: window.frame)
            animateFrame(to: hidden, duration: 0.16, token: token, completion: finish)
        } else { finish() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func windowDidMove(_ notification: Notification) { saveFloatingFrame() }
    func windowDidEndLiveResize(_ notification: Notification) {
        if appearance.mode == .floating { saveFloatingFrame() }
        else {
            let width = max(340, window.frame.width - (appearance.sidebarVisible ? 182 : 0))
            UserDefaults.standard.set(width, forKey: "historyAppearance.sideWidth")
            positionDockedWindow()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        outsideInteractionToken += 1
        commandHeld = NSEvent.modifierFlags.contains(.command); updateVisibleCards()
    }
    func windowDidResignKey(_ notification: Notification) {
        if dragSourceID != nil {
            invalidateReveal()
            for index in cards.visibleIndices() { cards.card(at: index)?.hideConcealedContent() }
        }
        closeIfUnfocused()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard isPinned, window.isVisible, !isClosing else { return }
        if dragSourceID != nil {
            invalidateReveal()
            for index in cards.visibleIndices() { cards.card(at: index)?.hideConcealedContent() }
            return
        }
        focusToken += 1
        cancelShortcutGesture()
        dismissPreview()
        remaskConcealedText()
    }

    private func remaskConcealedText() {
        let revealedRow = revealed.flatMap { value in rows.firstIndex(where: { $0.id == value.id }) }
        invalidateReveal()
        commandHeld = false
        if let revealedRow { cards.reloadCard(at: revealedRow) }
        updateVisibleCards()
    }

    enum OutsideInteractionSource: String {
        case localMouse, globalMouse, applicationActivation
    }

    func observeMouseDown(_ event: NSEvent, source: OutsideInteractionSource) {
        guard window.isVisible, !isClosing else { return }
        let eventWindow = event.window
        // AppKit can send unassociated mouse events in screen coordinates,
        // including the non-content part of a window. nil is not "outside".
        let belongsToPanel = eventWindow === window || event.windowNumber == window.windowNumber
        let screenPoint = eventWindow.map { $0.convertPoint(toScreen: event.locationInWindow) }
            ?? event.locationInWindow
        let insideFrame = window.frame.contains(screenPoint)
        // A foreign process can have a valid window number without an NSWindow
        // object in this app. Do not mistake its overlapping window for ours.
        let unassociated = eventWindow == nil && event.windowNumber <= 0
        let inside = belongsToPanel || (unassociated && insideFrame)
        logger.notice("Panel mouse: source=\(source.rawValue, privacy: .public), window=\(event.windowNumber), associated=\(eventWindow != nil), insideFrame=\(insideFrame), inside=\(inside), key=\(self.window.isKeyWindow)")
        if inside {
            outsideInteractionToken += 1
            return
        }
        dismissForOutsideInteraction(source: source)
    }

    func applicationDidActivate(_ app: NSRunningApplication) {
        guard window.isVisible, !isClosing,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              currentFrontmostApplication()?.processIdentifier == app.processIdentifier else { return }
        if isPinned { previousApp = app }
        else { dismissForOutsideInteraction(source: .applicationActivation, expectedApplicationPID: app.processIdentifier) }
    }

    // Mouse-down, not mouse-up: dropping a record leaves the panel available
    // for another drag. This also works when it has already lost key status.
    func dismissForOutsideInteraction(source: OutsideInteractionSource = .localMouse,
                                      expectedApplicationPID: pid_t? = nil) {
        guard window.isVisible, !isClosing, !isPinned, dragSourceID == nil,
              nearbyIntroduction == nil, window.attachedSheet == nil,
              !filters.isPresenting, !cardMenuTracking, !preview.isShown else { return }
        let token = presentationToken
        let interactionToken = outsideInteractionToken
        // AppKit tracks buttons in a nested run loop. Wait for tracking to
        // finish so the pin action can run before deciding whether to dismiss.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, token == self.presentationToken, interactionToken == self.outsideInteractionToken,
                  self.window.isVisible, !self.isClosing, !self.isPinned, self.dragSourceID == nil,
                  self.nearbyIntroduction == nil, self.window.attachedSheet == nil,
                  !self.filters.isPresenting, !self.cardMenuTracking, !self.preview.isShown else { return }
            if let expectedApplicationPID,
               self.currentFrontmostApplication()?.processIdentifier != expectedApplicationPID { return }
            self.logger.notice("Panel dismissal: source=\(source.rawValue, privacy: .public), key=\(self.window.isKeyWindow)")
            self.close(restoreFocus: false)
        }
    }

    private func closeIfUnfocused() {
        guard dragSourceID == nil, nearbyIntroduction == nil else { return }
        // Filter menus, calendar popovers and save sheets can own keyboard input.
        if !window.isKeyWindow, window.attachedSheet == nil, !filters.isPresenting,
           !cardMenuTracking, !preview.isShown {
            focusToken += 1
            cancelShortcutGesture()
            if isPinned { remaskConcealedText() }
        }
        let token = presentationToken
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, token == self.presentationToken, self.window.isVisible, !self.isClosing, !self.window.isKeyWindow,
                  self.window.attachedSheet == nil, !self.filters.isPresenting,
                  self.dragSourceID == nil, self.nearbyIntroduction == nil, !self.cardMenuTracking, !self.preview.isShown else { return }
            guard !self.isPinned else { return }
            self.logger.notice("Panel dismissal: focus loss")
            self.close(restoreFocus: false)
        }
    }

    func setSources(_ sources: [String]) { filters.setSources(sources) }
    func showConcealedText(_ text: String?, id: Int64, token: Int) {
        guard token == revealToken, window.isVisible, selected?.id == id, selected?.isConcealed == true else { return }
        revealing = false
        guard let text else { status.stringValue = L10n.text("В записи нет текста для показа."); updateSelection(); return }
        revealed = (id, String(text.prefix(4_000)))
        cards.reloadCard(at: cards.selectedIndex)
        updateSelection()
    }

    private func invalidateReveal() {
        if let id = revealed?.id, let row = rows.firstIndex(where: { $0.id == id }) {
            // Collection-view reloads may keep an outgoing cell in the view tree.
            // Remove plaintext before replacing it, including accessibility text.
            cards.card(at: row)?.hideConcealedContent()
        }
        revealToken += 1; revealed = nil; revealing = false
    }

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
        if event.keyCode == 53 {
            if isConfirmingCopyTransform { cancelCopyTransform(); return nil }
            if preview.isShown { dismissPreview(); window.makeKey(); window.makeFirstResponder(cards) }
            else if !isPinned { close() }
            return nil
        }
        if confirming || commitWhenLoaded { return nil }
        // Match the configured pair before ordinary local commands. Extra
        // modifiers must never turn a different command into navigation.
        if let delta = shortcuts.direction(keyCode: event.keyCode, modifiers: flags) {
            shortcutPressed(delta, isRepeat: event.isARepeat)
            return nil
        }
        if event.keyCode == 36 || event.keyCode == 76 { dismissPreview(); confirm(); return nil }
        if event.keyCode == 125 { move(cards.effectiveColumns); return nil }
        if event.keyCode == 126 { move(-cards.effectiveColumns); return nil }
        if !editingSearch, event.keyCode == 124 { move(1); return nil }
        if !editingSearch, event.keyCode == 123 { move(-1); return nil }
        if flags.contains(.command), event.keyCode == 43 { showSettings(); return nil }
        if flags.intersection([.command, .option, .control, .shift]) == [.command, .option], event.keyCode == 1 { toggleSidebar(); return nil }
        if event.keyCode == 48 {
            if isShowingNearby { window.makeFirstResponder(cards); return nil }
            window.makeFirstResponder(editingSearch ? cards : search); return nil
        }
        if flags.intersection([.command, .option, .control, .shift]) == .command && event.keyCode == 3 {
            if isShowingNearby { returnFromNearby() }
            dismissPreview(); window.makeFirstResponder(search); return nil
        }
        if flags.intersection([.command, .option, .control, .shift]) == .command ||
            flags.intersection([.command, .option, .control, .shift]) == [.command, .shift] {
            let quickKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if !flags.contains(.shift), let index = quickKeys[event.keyCode] {
                if rows.indices.contains(index) { select(id: rows[index].id); confirm() }
                return nil
            }
            if event.keyCode == 29 { resetEverything(); return nil }
            if event.keyCode == 16 { previewSelected(); return nil } // ⌘Y
            if flags.contains(.shift) {
                if event.keyCode == 8 { performSelected(.copyDifferently); return nil }
                if event.keyCode == 45 { performSelected(.nearby); return nil }
                if event.keyCode == 4 { performSelected(.reveal); return nil }
                if event.keyCode == 15 { performSelected(.finder); return nil }
                if event.keyCode == 1 { performSelected(.save); return nil }
            }
            if event.keyCode == 2 { performSelected(.favorite); return nil }
            // The search field owns Command-Delete's standard text-editing action.
            if event.keyCode == 51, !editingSearch { performSelected(.delete); return nil }
        }
        if event.keyCode == 49 && !editingSearch && flags.intersection([.command, .option, .control]).isEmpty {
            previewSelected(); return nil
        }
        // Starting to type from the list moves into search. Spaces in an active
        // search field retain their ordinary meaning for multiword queries.
        if !editingSearch, flags.intersection([.command, .option, .control]).isEmpty,
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            if isShowingNearby { returnFromNearby() }
            search.stringValue = characters
            window.makeFirstResponder(search)
            if let editor = search.currentEditor() { editor.selectedRange = NSRange(location: (characters as NSString).length, length: 0) }
            refresh(); return nil
        }
        return event
    }

    private var editingSearch: Bool {
        window.firstResponder === search || (search.currentEditor() != nil && window.firstResponder === search.currentEditor())
    }

    private func confirm() {
        cancelShortcutGesture()
        guard !isClosing, nearbyIntroduction == nil, !confirming, !filters.isPresenting, !cardMenuTracking, window.attachedSheet == nil else { return }
        if loading && rows.isEmpty {
            commitWhenLoaded = true; search.isEnabled = false; filters.setInteractionEnabled(false)
            scope.isEnabled = false; semanticSearch.isEnabled = false; updateVisibleCards()
            status.stringValue = L10n.text("Ожидаем историю…"); logger.notice("Confirm waiting for history")
            return
        }
        guard let selected else { close(); return }
        confirming = true; search.isEnabled = false; filters.setInteractionEnabled(false)
        scope.isEnabled = false; semanticSearch.isEnabled = false; updateVisibleCards()
        status.stringValue = L10n.text("Копируем в буфер…")
        logger.notice("Confirm requested")
        onConfirm?(selected.id)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, !filters.isPresenting, !cardMenuTracking, window.attachedSheet == nil else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
            confirm(); return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }
    @objc private func scopeChanged() { refresh() }
    @objc private func searchModeChanged() { refresh(preservingSelection: true) }
    @objc private func resetEverything() {
        guard !confirming, !commitWhenLoaded else { return }
        resetNavigationState()
        window.makeFirstResponder(cards); refresh()
    }

    private func resetNavigationState() {
        restoreSearchFromNearby(reloadIfNeeded: false, render: false)
        search.stringValue = ""; filters.reset(); scope.selectedSegment = 0
        retainedSelectionID = nil; pendingSelectionID = nil; recentCaptureID = nil
        retainedRowCount = 150; pendingViewport = nil
    }

    private func select(id: Int64, scrollIntoView: Bool = true) {
        guard let row = rows.firstIndex(where: { $0.id == id }) else { return }
        cards.select(row, scrollIntoView: scrollIntoView)
        updateSelection()
        window.makeFirstResponder(cards)
    }

    private func performSelected(_ action: ClipCardAction) {
        if let selected { perform(action, id: selected.id) }
    }

    private func perform(_ action: ClipCardAction, id: Int64) {
        guard nearbyIntroduction == nil else { return }
        guard !isClosing, !confirming, !commitWhenLoaded, window.attachedSheet == nil,
              let clip = rows.first(where: { $0.id == id }) else { return }
        select(id: id, scrollIntoView: false)
        if action != .preview { dismissPreview() }
        switch action {
        case .copy: confirm()
        case .preview: previewSelected()
        case .favorite:
            guard !pendingFavorites.contains(id) else { return }
            nearbyState?.needsReload = true
            pendingFavorites.insert(id); updateVisibleCards()
            onFavorite?(id, !clip.isFavorite)
        case .reveal:
            if clip.isConcealed || clip.kind == .text || clip.kind == .link { revealSelected() }
        case .finder, .save:
            guard clip.kind == .image, !clip.isConcealed else { return }
            onExport?(id, action == .save)
        case .delete: onDelete?(id)
        case .nearby: requestShowNearby(id: id)
        case .copyDifferently: showCopyTransform(clip)
        }
    }

    private func showCopyTransform(_ clip: ClipSummary) {
        guard ClipCardAction.copyDifferently.isAvailable(for: clip), pendingFavorites.isEmpty,
              let row = rows.firstIndex(where: { $0.id == clip.id }), let card = cards.card(at: row) else { return }
        cancelShortcutGesture(); dismissPreview()
        prepareCopyTransformOperations(for: clip, card: card)
        card.showCopyTransformMenu()
    }

    private func prepareCopyTransformOperations(for clip: ClipSummary, card: ClipCardView) {
        guard ClipCardAction.copyDifferently.isAvailable(for: clip), let requestCopyTransformOperations else { return }
        if copyOptionsID == clip.id {
            card.setCopyTransformOperations(copyOptions)
            return
        }
        copyOptionsToken += 1
        let token = copyOptionsToken
        copyOptionsID = clip.id; copyOptions = nil
        card.setCopyTransformOperations(nil)
        requestCopyTransformOperations(clip.id) { [weak self, weak card] result in
            guard let self, self.copyOptionsToken == token, self.copyOptionsID == clip.id,
                  self.window.isVisible else { return }
            let operations = (try? result.get()) ?? []
            self.copyOptions = operations
            card?.setCopyTransformOperations(operations)
            for row in self.cards.visibleIndices() where self.rows.indices.contains(row) && self.rows[row].id == clip.id {
                self.cards.card(at: row)?.setCopyTransformOperations(operations)
            }
        }
    }

    private func copyTransformed(_ operation: CopyTransformOperation, id: Int64) {
        guard isAvailableForShortcut, !confirming, !commitWhenLoaded, pendingFavorites.isEmpty,
              window.attachedSheet == nil, let clip = rows.first(where: { $0.id == id }),
              ClipCardAction.copyDifferently.isAvailable(for: clip),
              copyOptionsID == id, copyOptions?.contains(operation) == true,
              let requestCopyTransform, let onCopyTransformed else { return }
        select(id: id, scrollIntoView: false)
        copyTransformHistoryDirty = loading || silentSearchRefresh || searchIndexDirty
        onNavigate?()
        cancelShortcutGesture(); cancelSearchIndexRefresh(); dismissPreview(); invalidateReveal()
        loading = false; confirming = true; copyTransformSourceID = id
        copyTransformToken += 1
        let token = copyTransformToken
        updateNavigationControls(); updateVisibleCards()
        status.stringValue = L10n.text("Копируем: \(operation.title)…")
        requestCopyTransform(id, operation) { [weak self] result in
            guard let self, token == self.copyTransformToken, self.isConfirmingCopyTransform,
                  self.isAvailableForShortcut else { return }
            switch result {
            case .failure(let error): self.copyTransformFailed(error)
            case .success(let text):
                onCopyTransformed(id, operation, text) { [weak self] error in
                    guard let self, token == self.copyTransformToken, self.isConfirmingCopyTransform,
                          self.isAvailableForShortcut else { return }
                    if let error { self.copyTransformFailed(error) }
                    else { self.closeAfterConfirmation() }
                }
            }
        }
    }

    private func cancelCopyTransform(refreshHistory: Bool = true) {
        guard copyTransformSourceID != nil else { return }
        copyTransformToken += 1; copyTransformSourceID = nil
        let dirty = copyTransformHistoryDirty
        copyTransformHistoryDirty = false; confirming = false
        onCancelCopyTransformed?()
        updateNavigationControls(); updateVisibleCards()
        if refreshHistory {
            if dirty { refresh(preservingSelection: true) }
            else { updateCount() }
        }
    }

    private func copyTransformFailed(_ error: Error) {
        cancelCopyTransform()
        status.stringValue = error.localizedDescription
    }

    func favoriteFinished(id: Int64, isFavorite: Bool, error: Error?) {
        guard pendingFavorites.remove(id) != nil else { return }
        guard window.isVisible else { return }
        if let error {
            updateVisibleCards(); status.stringValue = error.localizedDescription
            return
        }
        if isShowingNearby { nearbyState?.needsReload = true }
        guard let row = rows.firstIndex(where: { $0.id == id }) else { return }
        if !isShowingNearby && scope.selectedSegment == 1 && !isFavorite {
            removeFavoriteRow(row)
        } else {
            let clip = rows[row]
            let updated = ClipSummary(id: clip.id, date: clip.date, kind: clip.kind, title: clip.title,
                                      text: clip.text, source: clip.source, byteCount: clip.byteCount,
                                      isConcealed: clip.isConcealed, isFavorite: isFavorite, isRemote: clip.isRemote)
            rows[row] = updated
            cards.card(at: row)?.updateFavorite(updated)
            updateVisibleCards()
        }
        scrolled()
    }

    private func removeFavoriteRow(_ row: Int) {
        let selectedID = selected?.id
        rows.remove(at: row); total = max(0, total - 1)
        let index = rows.firstIndex(where: { $0.id == selectedID }) ?? min(row, rows.count - 1)
        cards.remove(at: row, selectedIndex: index)
        updateSelection(); updateCount()
    }

    private func updateCount() {
        if let context = nearbyState {
            status.stringValue = context.title
            status.toolTip = L10n.text("\(context.title)\nЗаписей: \(total). Все типы и приложения.")
            return
        }
        status.toolTip = searchFallbackReason
        status.stringValue = L10n.text("Записей: \(total.formatted(.number.locale(L10n.locale)))")
        if !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, searchFallbackReason == nil {
            status.toolTip = actualSearchMode == .hybrid
                ? L10n.text("Найдены совпадения текста и похожие по смыслу записи.")
                : L10n.text("Найдены совпадения текста.")
        }
    }

    private func previewSelected() {
        if preview.isShown { dismissPreview(); return }
        guard let clip = selected else { return }
        previewToken += 1
        if clip.isConcealed {
            guard revealed?.id == clip.id else { status.stringValue = L10n.text("Сначала нажмите «Показать» на скрытой записи."); return }
            showPreview(.text(revealed!.text), id: clip.id, token: previewToken)
        } else {
            previewRequestPending = onPreview != nil
            onPreview?(clip, previewToken)
        }
    }

    func showPreview(_ content: ClipPreviewContent, id: Int64, token: Int) {
        guard token == previewToken else { return }
        previewRequestPending = false
        guard window.isVisible, selected?.id == id,
              !filters.isPresenting, !cardMenuTracking, window.attachedSheet == nil,
              !confirming, !commitWhenLoaded,
              let row = rows.firstIndex(where: { $0.id == id }),
              let card = cards.card(at: row) else { return }
        preview.show(content, title: selected?.isConcealed == true ? L10n.text("Скрытая запись") : (selected?.kind.label ?? L10n.text("Просмотр")),
                     isConcealed: selected?.isConcealed == true, relativeTo: card)
    }

    private func dismissPreview() { previewToken += 1; previewRequestPending = false; preview.close() }
    @objc private func revealSelected() {
        guard let selected else { return }
        if !selected.isConcealed { onConceal?(selected.id); return }
        if revealed?.id == selected.id {
            invalidateReveal()
            cards.reloadCard(at: cards.selectedIndex)
            updateSelection()
        } else {
            revealToken += 1; revealing = true; updateSelection()
            onReveal?(selected.id, revealToken)
        }
    }
    private func scrolled() { if cards.isNearEnd { loadMore() } }
    private func loadMore() {
        guard window.isVisible, !isClosing, !isShowingNearby, !loading, !silentSearchRefresh, rows.count < total else { return }
        // Removing a favorite changes subsequent offsets. Wait until the local
        // rows reflect committed removals before requesting another page.
        guard scope.selectedSegment != 1 || pendingFavorites.isEmpty else { return }
        loading = true; request?(filter(), rows.count, 150)
    }

    private var canRefreshSearchIndex: Bool {
        window.isVisible && !isClosing && !isShowingNearby && !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchIndexInteractionIsIdle: Bool {
        !confirming && !commitWhenLoaded && !preview.isShown && !previewRequestPending && !revealing
            && !cardMenuTracking && !filters.isPresenting
            && window.attachedSheet == nil && pendingFavorites.isEmpty
    }

    private func scheduleSearchIndexRefresh(after delay: TimeInterval) {
        guard searchIndexTimer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.searchIndexTimer = nil
            self.refreshSearchIndexIfReady()
        }
        searchIndexTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSearchIndexRefresh() {
        searchIndexTimer?.invalidate(); searchIndexTimer = nil
        searchIndexDirty = false; silentSearchRefresh = false
    }

    private func refreshSearchIndexIfReady() {
        guard searchIndexDirty else { return }
        guard canRefreshSearchIndex else { cancelSearchIndexRefresh(); return }
        guard searchIndexInteractionIsIdle, !loading, !silentSearchRefresh else {
            scheduleSearchIndexRefresh(after: 0.8)
            return
        }
        guard let request else { return }
        searchIndexDirty = false
        silentSearchRefresh = true; loading = true
        request(filter(), 0, max(150, rows.count + 150))
    }

    private func receiveSearchIndexResult(_ result: [ClipSummary], total: Int) {
        silentSearchRefresh = false; loading = false
        guard canRefreshSearchIndex else { cancelSearchIndexRefresh(); return }
        if commitWhenLoaded && rows.isEmpty {
            // Enter while waiting for the first OCR match owns this result just
            // like Enter during an ordinary search; it cannot wait for itself.
            receive(result, total: total, offset: 0)
            return
        }
        // The user can start a preview, confirmation or menu while SQL is still
        // running. Requery when that interaction finishes rather than replacing it.
        guard searchIndexInteractionIsIdle else {
            searchIndexDirty = true
            scheduleSearchIndexRefresh(after: 0.8)
            return
        }
        self.total = total
        if let selectedID = selected?.id, !result.contains(where: { $0.id == selectedID }),
           result.count < total, let request {
            // OCR can insert many newer matches ahead of the current choice.
            // Fetch far enough to keep it before changing the visible records.
            silentSearchRefresh = true; loading = true
            request(filter(), 0, min(total, max(result.count + 150, result.count * 2)))
            return
        }
        if !displayedRowsAreUnchanged(in: result) {
            let selectedID = selected?.id
            let previousIndex = cards.selectedIndex
            rows = result
            let index = selectedID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
                ?? (rows.isEmpty ? -1 : max(0, min(previousIndex, rows.count - 1)))
            cards.replace(count: rows.count, selectedIndex: index)
            updateSelection()
        }
        updateCount()
        scrolled()
        if searchIndexDirty { scheduleSearchIndexRefresh(after: 0.8) }
    }

    private func displayedRowsAreUnchanged(in result: [ClipSummary]) -> Bool {
        guard result.count >= rows.count, !rows.isEmpty || result.isEmpty else { return false }
        // The wider query may include an extra page. An unchanged visible prefix
        // needs only its count updated; regular pagination will fetch the rest.
        return zip(rows, result).allSatisfy { current, updated in
            current.id == updated.id && current.date == updated.date && current.kind == updated.kind
                && current.title == updated.title && current.text == updated.text && current.source == updated.source
                && current.byteCount == updated.byteCount && current.isConcealed == updated.isConcealed
                && current.isFavorite == updated.isFavorite && current.isRemote == updated.isRemote
        }
    }

    private func filter() -> SearchFilter {
        var filter = SearchFilter(); filter.query = search.stringValue
        filter.favoritesOnly = scope.selectedSegment == 1
        filters.apply(to: &filter)
        return filter
    }

    private func makeCard(at row: Int) -> ClipCardView {
        let clip = rows[row]
        let card = ClipCardView(clip: clip, revealedText: revealed?.id == clip.id ? revealed?.text : nil,
                                thumbnail: thumbnails.object(forKey: NSNumber(value: clip.id))) { [weak self] action in
            // Context menu actions run after tracking has ended, through the same
            // path as buttons and keyboard actions.
            DispatchQueue.main.async { self?.perform(action, id: clip.id) }
        }
        card.onRequestCopyTransformOperations = { [weak self, weak card] in
            guard let self, let card else { return }
            self.prepareCopyTransformOperations(for: clip, card: card)
        }
        card.onCopyTransform = { [weak self] operation in
            DispatchQueue.main.async { self?.copyTransformed(operation, id: clip.id) }
        }
        card.onMenuTracking = { [weak self] tracking in
            self?.cardMenuTracking = tracking
            if !tracking { self?.closeIfUnfocused() }
        }
        card.requestDrag = { [weak self, weak card] completion in
            guard let self, let card, self.isAvailableForShortcut, !self.confirming,
                  !self.commitWhenLoaded, !self.loading, !self.silentSearchRefresh,
                  self.pendingFavorites.isEmpty, self.window.attachedSheet == nil,
                  let request = self.requestDragPayload else {
                completion(.failure(ClipDragFailure.unreadable)); return
            }
            self.cancelShortcutGesture(); self.cancelSearchIndexRefresh(); self.dismissPreview()
            self.dragSourceID = clip.id; self.dragHistoryDirty = false
            self.cancelDragPreparation = { [weak card] in card?.cancelDragPreparation() }
            self.confirming = true
            self.updateNavigationControls(); self.updateVisibleCards()
            request(clip.id, completion)
        }
        card.onDragFinished = { [weak self] operation, error in
            self?.dragFinished(id: clip.id, operation: operation, error: error)
        }
        configure(card, row: row)
        if ClipboardService.canPreviewImage(clip) && thumbnails.object(forKey: NSNumber(value: clip.id)) == nil {
            requestThumbnail?(clip.id) { [weak self, weak card] image in
                guard let image else { return }
                self?.thumbnails.setObject(image, forKey: NSNumber(value: clip.id))
                card?.setThumbnail(image)
            }
        }
        return card
    }

    private func dragFinished(id: Int64, operation: NSDragOperation, error: Error?) {
        guard dragSourceID == id else {
            if let error { status.stringValue = error.localizedDescription }
            return
        }
        dragSourceID = nil; cancelDragPreparation = nil; confirming = false
        let needsRefresh = dragHistoryDirty
        dragHistoryDirty = false
        updateNavigationControls(); updateVisibleCards()
        if operation.contains(.copy) {
            recentCaptureID = nil
            onDragCompleted?(id)
        }
        if needsRefresh { refresh(preservingSelection: true) }
        if let error { failed(error) }
        if searchIndexDirty { scheduleSearchIndexRefresh(after: 0.8) }
    }

    private func configure(_ card: ClipCardView, row: Int) {
        card.setSelected(cards.selectedIndex == row)
        card.setCopyTransformOperations(copyOptionsID == rows[row].id ? copyOptions : nil)
        if cards.selectedIndex == row { prepareCopyTransformOperations(for: rows[row], card: card) }
        card.setNearbyAnchor(nearbyState?.anchorID == rows[row].id)
        card.setQuickShortcut(commandHeld && row < 9 ? row + 1 : nil)
        card.setActionsEnabled(!confirming && !commitWhenLoaded && !pendingFavorites.contains(rows[row].id)
                               && !(revealing && selected?.id == rows[row].id))
    }

    private func updateVisibleCards() {
        nearbyBack.isEnabled = !confirming && !commitWhenLoaded
        pinButton.isEnabled = !confirming && !commitWhenLoaded
        for index in cards.visibleIndices() where rows.indices.contains(index) {
            if let card = cards.card(at: index) { configure(card, row: index) }
        }
    }

    private func updateSelection() {
        if lastSelectedID != selected?.id {
            let previous = revealed?.id
            dismissPreview()
            invalidateReveal(); lastSelectedID = selected?.id
            if let previous, let row = rows.firstIndex(where: { $0.id == previous }) {
                cards.reloadCard(at: row)
            }
        }
        updateVisibleCards()
    }

    @objc func showSettings() {
        guard !isClosing, !confirming, !commitWhenLoaded else { return }
        dismissPreview(); filters.dismiss()
        onShowSettings?()
    }

    @objc private func toggleSidebar() {
        guard !isClosing, !confirming, !commitWhenLoaded else { return }
        var value = appearance; value.sidebarVisible.toggle(); applyAppearance(value)
    }

    private func configureAppearance() {
        cards.columns = appearance.columns
        cards.visibleRows = appearance.visibleRows
        cards.sizesToContent = appearance.mode != .floating
        filters.setSidebarVisible(appearance.sidebarVisible)
        filters.sidebar.isHidden = !appearance.sidebarVisible
        sidebarWidth.isActive = appearance.sidebarVisible
        sidebarButton.state = appearance.sidebarVisible ? .on : .off
        sidebarButton.toolTip = appearance.sidebarVisible ? L10n.text("Скрыть боковое меню · ⌘⌥S") : L10n.text("Показать боковое меню · ⌘⌥S")
        window.isMovableByWindowBackground = appearance.mode == .floating
        window.isMovable = appearance.mode == .floating
        bodyMinimumHeight.constant = appearance.sidebarVisible ? 320 : 260
        window.minSize = NSSize(width: appearance.sidebarVisible ? 480 : 340,
                                height: appearance.sidebarVisible ? 494 : 434)
    }

    func applyAppearance(_ value: HistoryAppearance) {
        let previous = appearance
        guard previous != value else { return }
        // Settings can change while the docked picker is still sliding out.
        // Finish that close before replacing the animation's geometry/token.
        if isClosing {
            presentationToken += 1
            window.orderOut(nil)
            window.permitsOffscreenFrame = false
            isClosing = false
        }
        saveFloatingFrame()
        appearance = value; appearance.save()
        if previous.mode != value.mode {
            presentationToken += 1
            window.permitsOffscreenFrame = false
        }
        configureAppearance()
        changingFrame = true
        if appearance.mode == .floating {
            if previous.mode != .floating { _ = window.setFrameUsingName(Self.frameName) }
            if previous.columns != value.columns {
                var frame = window.frame
                let width = CGFloat(appearance.columns) * 244 + CGFloat(max(0, appearance.columns - 1)) * 8 + (appearance.sidebarVisible ? 182 : 0) + 28
                frame.size.width = max(window.minSize.width, width)
                window.setFrame(frame, display: true)
            }
            keepOnScreen()
        } else { positionDockedWindow() }
        changingFrame = false
        saveFloatingFrame()
        window.contentView?.layoutSubtreeIfNeeded()
        cards.scrollToSelection()
        onAppearanceChange?(appearance)
    }

    private func saveFloatingFrame() {
        guard appearance.mode == .floating, !changingFrame else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    private func positionDockedWindow() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? window.screen ?? NSScreen.main else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let stored = UserDefaults.standard.double(forKey: "historyAppearance.sideWidth")
        let columnsWidth = CGFloat(appearance.columns) * HistoryCardsMetrics.minimumWidth
            + CGFloat(appearance.columns - 1) * HistoryCardsMetrics.gap + 28
        let baseWidth = max(columnsWidth, stored > 0 ? max(340, stored) : 360)
        let width = min(bounds.width, baseWidth + (appearance.sidebarVisible ? 182 : 0))
        let x = appearance.mode == .left ? bounds.minX : bounds.maxX - width
        window.setFrame(NSRect(x: x, y: bounds.minY, width: width, height: bounds.height), display: window.isVisible)
    }

    private func hiddenFrame(for frame: NSRect) -> NSRect {
        var hidden = frame
        hidden.origin.x += appearance.mode == .left ? -(frame.width + 16) : frame.width + 16
        return hidden
    }

    /// Each open/close invalidates preceding frames, including a rapid hotkey reopen.
    private func animateFrame(to target: NSRect, duration: TimeInterval, token: Int, completion: @escaping () -> Void) {
        let start = window.frame
        let startedAt = ProcessInfo.processInfo.systemUptime
        func step() {
            guard token == presentationToken else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let progress = min(1, elapsed / duration)
            let eased = 1 - pow(1 - progress, 3)
            let x = start.origin.x + (target.origin.x - start.origin.x) * eased
            window.setFrame(NSRect(x: x, y: target.minY, width: target.width, height: target.height), display: true)
            if progress == 1 { completion() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 60) { step() } }
        }
        step()
    }

    private func build() {
        window.title = BrandIdentity.name; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.level = .floating
        window.isMovableByWindowBackground = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isOpaque = false; window.backgroundColor = .clear
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        let background = HistoryBackdropView(frame: window.contentView!.bounds)
        window.contentView = background
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 10, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: background.leadingAnchor), root.trailingAnchor.constraint(equalTo: background.trailingAnchor), root.topAnchor.constraint(equalTo: background.topAnchor), root.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
        search.placeholderString = L10n.text("Найти в истории"); search.delegate = self; search.font = .systemFont(ofSize: 15)
        search.sendsSearchStringImmediately = true; search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        resetSearch.target = self; resetSearch.action = #selector(resetEverything)
        resetSearch.toolTip = L10n.text("Вся история · ⌘0")
        sidebarButton.target = self; sidebarButton.action = #selector(toggleSidebar)
        settingsButton.target = self; settingsButton.action = #selector(showSettings)
        settingsButton.toolTip = L10n.text("Настройки · ⌘,")
        pinButton.setButtonType(.toggle)
        pinButton.imagePosition = .imageOnly
        pinButton.target = self; pinButton.action = #selector(togglePinned)
        pinButton.identifier = NSUserInterfaceItemIdentifier("history.pin")
        for button in [sidebarButton, resetSearch, settingsButton, pinButton] {
            button.isBordered = false; button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.contentTintColor = .secondaryLabelColor
        }
        updatePinButton()
        let searchRow = NSStackView(views: [sidebarButton, search, resetSearch, filters, settingsButton, pinButton]); searchRow.spacing = 6; searchRow.distribution = .fill
        searchRow.alignment = .centerY
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbar = HistoryGlassToolbar(controls: searchRow)
        root.addArrangedSubview(toolbar)
        toolbar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true
        scope.selectedSegment = 0; scope.segmentStyle = .rounded
        scope.selectedSegmentBezelColor = BrandIdentity.accentColor
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.setImage(NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil), forSegment: 0)
        scope.setImage(NSImage(systemSymbolName: "star", accessibilityDescription: nil), forSegment: 1)
        semanticSearch.state = .on
        semanticSearch.controlSize = .small
        semanticSearch.font = .systemFont(ofSize: 12)
        semanticSearch.target = self
        semanticSearch.action = #selector(searchModeChanged)
        semanticSearch.identifier = NSUserInterfaceItemIdentifier("history.searchMode")
        semanticSearch.setAccessibilityLabel(semanticSearch.title)
        semanticSearch.toolTip = L10n.text("Дополнять совпадения текста похожими по смыслу записями. Включите «Поиск по смыслу» в настройках.")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        status.alignment = .right
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nearbyBack.identifier = .init("history.nearbyBack")
        nearbyBack.target = self; nearbyBack.action = #selector(returnFromNearby)
        nearbyBack.bezelStyle = .rounded
        nearbyBack.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        nearbyBack.imagePosition = .imageLeading
        nearbyBack.toolTip = L10n.text("Назад в историю")
        nearbyBack.setAccessibilityLabel(L10n.text("Назад в историю"))
        nearbyBack.isHidden = true
        chatButton.target = self; chatButton.action = #selector(showChat)
        chatButton.toolTip = L10n.text("Спросить Buffera о том, что вы копировали")
        chatButton.setAccessibilityLabel(L10n.text("Спросить Buffera"))
        chatButton.identifier = NSUserInterfaceItemIdentifier("history.chat")
        let searchOptionsSpacer = NSView()
        searchOptionsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchOptionsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [semanticSearch, semanticSetup, searchOptionsSpacer, chatButton].forEach(searchOptionsRow.addArrangedSubview)
        searchOptionsRow.identifier = NSUserInterfaceItemIdentifier("history.searchOptions")
        searchOptionsRow.spacing = 8; searchOptionsRow.distribution = .fill; searchOptionsRow.alignment = .centerY
        root.addArrangedSubview(searchOptionsRow)
        searchOptionsRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        root.setCustomSpacing(6, after: toolbar)
        root.setCustomSpacing(8, after: searchOptionsRow)
        semanticSetup.target = self; semanticSetup.action = #selector(setupSemanticSearch)
        semanticSetup.bezelStyle = .inline; semanticSetup.controlSize = .small
        semanticSetup.font = .systemFont(ofSize: 11)
        semanticSetup.lineBreakMode = .byTruncatingTail
        semanticSetup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        semanticSetup.identifier = .init("history.semanticSetup")
        nearbyHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        let help = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: L10n.text("Что копировал до и после"))!, target: self, action: #selector(explainNearby))
        help.bezelStyle = .inline; help.identifier = .init("history.nearbyHelp")
        nearbyHeader.orientation = .vertical; nearbyHeader.alignment = .leading; nearbyHeader.spacing = 8
        nearbyHeader.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        nearbyHeader.wantsLayer = true; nearbyHeader.layer?.cornerRadius = 10
        nearbyHeader.layer?.backgroundColor = BrandIdentity.accentColor.withAlphaComponent(0.10).cgColor
        let nearbyActions = NSStackView(views: [nearbyBack, NSView(), help])
        nearbyHeader.addArrangedSubview(nearbyHeading); nearbyHeader.addArrangedSubview(nearbyActions)
        nearbyHeading.widthAnchor.constraint(equalTo: nearbyHeader.widthAnchor, constant: -24).isActive = true
        nearbyActions.widthAnchor.constraint(equalTo: nearbyHeading.widthAnchor).isActive = true
        root.addArrangedSubview(nearbyHeader)
        nearbyHeader.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        nearbyHeader.identifier = .init("history.nearbyHeader"); nearbyHeader.isHidden = true
        let scopeRow = NSStackView(views: [scope, status]); scopeRow.spacing = 8; scopeRow.distribution = .fill
        scope.widthAnchor.constraint(equalToConstant: 210).isActive = true
        root.addArrangedSubview(scopeRow)
        scopeRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        contentRow.orientation = .horizontal; contentRow.alignment = .top; contentRow.distribution = .fill; contentRow.spacing = 12
        contentRow.addArrangedSubview(filters.sidebar); contentRow.addArrangedSubview(cards)
        root.addArrangedSubview(contentRow)
        contentRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        bodyMinimumHeight = contentRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        bodyMinimumHeight.isActive = true
        sidebarWidth = filters.sidebar.widthAnchor.constraint(equalToConstant: 170)
        sidebarWidth.isActive = true
        filters.sidebar.heightAnchor.constraint(equalTo: contentRow.heightAnchor).isActive = true
        cards.heightAnchor.constraint(equalTo: contentRow.heightAnchor).isActive = true
        cards.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.stringValue = L10n.text("↑↓ выбор   ↩ в буфер   Пробел просмотр   ⌘D избранное")
        root.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
        updateNavigationControls()
    }

    @objc private func togglePinned() {
        logger.notice("Panel pin changed: pinned=\(self.isPinned), closing=\(self.isClosing), key=\(self.window.isKeyWindow)")
        cancelShortcutGesture()
        updatePinButton()
        if !isPinned { closeIfUnfocused() }
    }

    private func updatePinButton() {
        let label = isPinned ? L10n.text("Открепить окно истории") : L10n.text("Закрепить окно истории")
        pinButton.toolTip = isPinned
            ? L10n.text("Открепить окно: скрывать при переходе в другое приложение")
            : L10n.text("Закрепить окно: оставить открытым при переходе в другое приложение")
        pinButton.setAccessibilityLabel(label)
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        pinButton.contentTintColor = isPinned ? BrandIdentity.accentColor : .secondaryLabelColor
    }

    @objc private func showChat() {
        guard chatAvailable, !confirming, !commitWhenLoaded else { return }
        onShowChat?()
    }
}
