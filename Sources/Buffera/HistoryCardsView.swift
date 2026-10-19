import AppKit

struct HistoryCardsMetrics: Equatable {
    static let gap: CGFloat = 8
    static let minimumWidth: CGFloat = 230
    static let minimumHeight: CGFloat = 96
    let columns: Int
    let itemSize: NSSize

    init(viewport: NSSize, requestedColumns: Int, visibleRows: Int) {
        let width = viewport.width.isFinite ? max(0, viewport.width) : 0
        let height = viewport.height.isFinite ? max(0, viewport.height) : 0
        let requested = min(4, max(1, requestedColumns))
        let fitting = max(1, Int(floor((width + Self.gap) / (Self.minimumWidth + Self.gap))))
        columns = min(requested, fitting)
        let rows = CGFloat(min(12, max(3, visibleRows)))
        itemSize = NSSize(width: max(1, floor((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns))),
                          height: max(Self.minimumHeight, floor((height - Self.gap * (rows - 1)) / rows)))
    }

    static func selection(_ index: Int, count: Int) -> Int {
        count > 0 && index >= 0 ? min(index, count - 1) : -1
    }
}

/// The panel owns records; this view owns reusable items, layout and scrolling.
final class HistoryCardsView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let scrollView = NSScrollView()
    var onSelect: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onNeedMore: (() -> Void)?
    var makeCard: ((Int) -> ClipCardView)?
    var heightForCard: ((Int, CGFloat, CGFloat) -> CGFloat)? { didSet { updateLayout(force: true) } }
    private(set) var selectedIndex = -1
    var columns = 1 { didSet { if oldValue != columns { updateLayout() } } }
    var visibleRows = 6 { didSet { if oldValue != visibleRows { updateLayout() } } }
    var sizesToContent = false { didSet { if oldValue != sizesToContent { updateLayout(force: true) } } }
    var effectiveColumns: Int { metrics.columns }

    private static let itemIdentifier = NSUserInterfaceItemIdentifier("HistoryCard")
    private let collectionView = CardsCollectionView()
    private let flow = CardsFlowLayout()
    private var itemCount = 0
    private var hasLoaded = false
    private var changingItems = false
    private var suppressSelection = false
    private var updatingLayout = false
    private var needMoreScheduled = false
    private var lastMetrics: HistoryCardsMetrics?
    private var measuredHeights: [Int: CGFloat] = [:]
    private var measuredMetrics: HistoryCardsMetrics?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var metrics: HistoryCardsMetrics {
        HistoryCardsMetrics(viewport: scrollView.contentView.bounds.size,
                            requestedColumns: columns, visibleRows: visibleRows)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        flow.minimumInteritemSpacing = HistoryCardsMetrics.gap
        flow.minimumLineSpacing = HistoryCardsMetrics.gap
        flow.sectionInset = .init(top: 0, left: 0, bottom: 0, right: 0)
        flow.scrollDirection = .vertical
        collectionView.collectionViewLayout = flow
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        // updateLayout coordinates document width with flow sizes; automatic
        // resizing would temporarily validate cached cards against a narrower view.
        collectionView.autoresizingMask = []
        collectionView.register(HistoryCardItem.self, forItemWithIdentifier: Self.itemIdentifier)
        collectionView.setAccessibilityLabel("История копирований")
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = collectionView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        updateLayout()
    }

    func reload(count: Int, selectedIndex: Int, scrollToSelection: Bool) {
        let origin = scrollView.contentView.bounds.origin
        let oldCount = itemCount
        let isAppend = hasLoaded && count > oldCount && !scrollToSelection
        if !isAppend { measuredHeights.removeAll(keepingCapacity: true) }
        changingItems = true
        suppressSelection = true
        itemCount = max(0, count)
        self.selectedIndex = HistoryCardsMetrics.selection(selectedIndex, count: itemCount)
        withoutAnimation {
            if isAppend {
                collectionView.insertItems(at: Set((oldCount..<itemCount).map(indexPath)))
            } else {
                collectionView.reloadData()
            }
        }
        hasLoaded = true
        flow.invalidateLayout()
        applyCollectionSelection()
        collectionView.layoutSubtreeIfNeeded()
        suppressSelection = false
        changingItems = false
        if scrollToSelection { self.scrollToSelection() } else { restoreViewport(origin) }
        scheduleNeedMore()
    }

    /// Replace a search result without treating a larger result as pagination.
    /// Existing scroll position is retained, and rows are never cleared first.
    func replace(count: Int, selectedIndex: Int) {
        hasLoaded = false
        reload(count: count, selectedIndex: selectedIndex, scrollToSelection: false)
    }

    func select(_ index: Int, scrollIntoView: Bool) {
        let next = HistoryCardsMetrics.selection(index, count: itemCount)
        let changed = selectedIndex != next
        selectedIndex = next
        applyCollectionSelection()
        if scrollIntoView { scrollToSelection() }
        window?.makeFirstResponder(collectionView)
        if changed { onSelect?(next) }
    }

    func card(at index: Int) -> ClipCardView? {
        guard (0..<itemCount).contains(index) else { return nil }
        return (collectionView.item(at: indexPath(index)) as? HistoryCardItem)?.card
    }

    func visibleIndices() -> [Int] {
        let visibleRect = collectionView.visibleRect
        return collectionView.indexPathsForVisibleItems().compactMap { path in
            guard path.section == 0, (0..<itemCount).contains(path.item),
                  let attributes = collectionView.layoutAttributesForItem(at: path),
                  attributes.frame.intersects(visibleRect) else { return nil }
            return path.item
        }.sorted()
    }

    func reloadCard(at index: Int) {
        guard (0..<itemCount).contains(index) else { return }
        let origin = scrollView.contentView.bounds.origin
        measuredHeights.removeValue(forKey: index)
        withoutAnimation { collectionView.reloadItems(at: [indexPath(index)]) }
        flow.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        restoreViewport(origin)
    }

    /// The caller removes its record before calling this method.
    func remove(at index: Int, selectedIndex: Int) {
        guard (0..<itemCount).contains(index) else { return }
        let origin = scrollView.contentView.bounds.origin
        changingItems = true
        suppressSelection = true
        itemCount -= 1
        measuredHeights.removeAll(keepingCapacity: true)
        self.selectedIndex = HistoryCardsMetrics.selection(selectedIndex, count: itemCount)
        withoutAnimation { collectionView.deleteItems(at: [indexPath(index)]) }
        flow.invalidateLayout()
        applyCollectionSelection()
        collectionView.layoutSubtreeIfNeeded()
        suppressSelection = false
        changingItems = false
        restoreViewport(origin)
        scheduleNeedMore()
    }

    func scrollToSelection() {
        guard (0..<itemCount).contains(selectedIndex) else { return }
        collectionView.layoutSubtreeIfNeeded()
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath(selectedIndex))?.frame else { return }
        collectionView.scrollToVisible(frame)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var isNearEnd: Bool {
        guard itemCount > 0, let last = visibleIndices().last else { return false }
        return last >= itemCount - max(12, effectiveColumns * 2)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { itemCount }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        // AppKit may query sizes between resizing the clip view and its document.
        // Stay inside both widths during that transition and remeasure when it settles.
        guard collectionView.bounds.width > 0 else { return .zero }
        var viewport = scrollView.contentView.bounds.size
        viewport.width = min(viewport.width, collectionView.bounds.width)
        let layout = HistoryCardsMetrics(viewport: viewport, requestedColumns: columns, visibleRows: visibleRows)
        if measuredMetrics != layout {
            measuredHeights.removeAll(keepingCapacity: true)
            measuredMetrics = layout
        }
        guard sizesToContent, let heightForCard, (0..<itemCount).contains(indexPath.item) else {
            return layout.itemSize
        }
        // Align cards within a grid row, while a single-column panel follows each record's height.
        let first = indexPath.item / layout.columns * layout.columns
        let end = min(itemCount, first + layout.columns)
        let height = (first..<end).map { index -> CGFloat in
            if let cached = measuredHeights[index] { return cached }
            let measured = heightForCard(index, layout.itemSize.width, layout.itemSize.height)
            let result = measured.isFinite && measured > 0 ? ceil(measured) : layout.itemSize.height
            measuredHeights[index] = result
            return result
        }.max() ?? layout.itemSize.height
        return NSSize(width: layout.itemSize.width, height: height)
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemIdentifier, for: path) as! HistoryCardItem
        guard let card = makeCard?(path.item) else { item.clear(); return item }
        item.install(card)
        card.setSelected(path.item == selectedIndex)
        card.onSelect = { [weak self, weak item] in
            guard let self, let item, let path = self.collectionView.indexPath(for: item) else { return }
            self.select(path.item, scrollIntoView: false)
        }
        card.onActivate = { [weak self, weak item] in
            guard let self, let item, let path = self.collectionView.indexPath(for: item) else { return }
            self.select(path.item, scrollIntoView: false)
            self.onActivate?(path.item)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) {
        guard !suppressSelection, let index = paths.map(\.item).min(), index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }

    private func indexPath(_ index: Int) -> IndexPath { IndexPath(item: index, section: 0) }

    private func applyCollectionSelection() {
        let wasSuppressed = suppressSelection
        suppressSelection = true
        collectionView.selectionIndexPaths = selectedIndex >= 0 ? [indexPath(selectedIndex)] : []
        for index in visibleIndices() { card(at: index)?.setSelected(index == selectedIndex) }
        suppressSelection = wasSuppressed
    }

    private func updateLayout(force: Bool = false) {
        guard !updatingLayout else { return }
        let next = metrics
        guard force || next != lastMetrics else { return }
        updatingLayout = true
        let origin = scrollView.contentView.bounds.origin
        lastMetrics = next
        measuredHeights.removeAll(keepingCapacity: true)
        flow.itemSize = next.itemSize
        flow.invalidateLayout()
        collectionView.setFrameSize(NSSize(width: max(1, scrollView.contentView.bounds.width),
                                           height: max(collectionView.frame.height, scrollView.contentView.bounds.height)))
        flow.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        restoreViewport(origin)
        updatingLayout = false
        scheduleNeedMore()
    }

    private func restoreViewport(_ origin: NSPoint) {
        let clip = scrollView.contentView
        let maxY = max(0, collectionView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, origin.y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        guard !changingItems, !updatingLayout else { return }
        updateLayout()
        scheduleNeedMore()
    }

    private func scheduleNeedMore() {
        guard !needMoreScheduled else { return }
        needMoreScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needMoreScheduled = false
            if self.window?.isVisible == true, !self.changingItems, self.isNearEnd { self.onNeedMore?() }
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            changes()
        }
    }
}

private final class CardsFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }

    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if newBounds.width != collectionView?.bounds.width {
            // The flow layout otherwise keeps delegate widths from before a resize.
            (context as? NSCollectionViewFlowLayoutInvalidationContext)?.invalidateFlowLayoutDelegateMetrics = true
        }
        return context
    }
}

private final class CardsCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class HistoryCardItem: NSCollectionViewItem {
    private(set) var card: ClipCardView?

    override var isSelected: Bool { didSet { card?.setSelected(isSelected) } }
    override func loadView() { view = NSView() }

    func install(_ card: ClipCardView) {
        clear()
        self.card = card
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func clear() {
        card?.onSelect = nil
        card?.onActivate = nil
        card?.removeFromSuperview()
        card = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }
}
