import AppKit

final class AppearanceSettings: NSObject, NSPopoverDelegate {
    var onChange: ((HistoryAppearance) -> Void)?
    var onClose: (() -> Void)?
    var isShown: Bool { popover.isShown }

    private let popover = NSPopover()
    private weak var parentWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var keyMonitor: Any?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    deinit { removeKeyMonitor() }

    func show(_ appearance: HistoryAppearance, relativeTo view: NSView) {
        if popover.isShown { close(); return }
        guard let window = view.window, window.isVisible else { return }
        parentWindow = window
        previousResponder = window.firstResponder
        let controller = AppearanceSettingsController(appearance: appearance)
        controller.onChange = { [weak self] value in self?.onChange?(value) }
        controller.onDone = { [weak self] in self?.closeReturningFocus() }
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        controller.view.window?.makeKey()
        controller.focusInitialControl()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak controller] event in
            guard let self, let controller, self.popover.isShown, !controller.isTrackingMenu,
                  event.window === controller.view.window, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            self.closeReturningFocus()
            return nil
        }
    }

    func close() {
        removeKeyMonitor()
        if popover.isShown { popover.close() }
    }

    func popoverDidClose(_ notification: Notification) {
        removeKeyMonitor()
        popover.contentViewController = nil
        parentWindow = nil; previousResponder = nil
        onClose?()
    }

    private func closeReturningFocus() {
        let window = parentWindow
        let responder = previousResponder
        close()
        if window?.isVisible == true {
            window?.makeKey()
            if let responder { window?.makeFirstResponder(responder) }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }
}

private final class AppearanceSettingsController: NSViewController, NSMenuDelegate {
    var onChange: ((HistoryAppearance) -> Void)?
    var onDone: (() -> Void)?
    private(set) var isTrackingMenu = false

    private var appearance: HistoryAppearance
    private let mode = NSPopUpButton()
    private let columns = NSPopUpButton()
    private let rows = NSPopUpButton()
    private let sidebar = NSButton(checkboxWithTitle: "Показывать боковую панель", target: nil, action: nil)

    init(appearance: HistoryAppearance) {
        self.appearance = appearance
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.widthAnchor.constraint(equalToConstant: 348).isActive = true
        let heading = NSTextField(labelWithString: "Вид окна")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        root.addArrangedSubview(heading)

        mode.addItems(withTitles: HistoryAppearance.Mode.allCases.map(\.title))
        mode.selectItem(at: HistoryAppearance.Mode.allCases.firstIndex(of: appearance.mode) ?? 0)
        columns.addItems(withTitles: ["1 — список", "2 — сетка", "3 — сетка", "4 — сетка"])
        columns.selectItem(at: appearance.columns - 1)
        rows.addItems(withTitles: (3...12).map(String.init))
        rows.selectItem(at: appearance.visibleRows - 3)
        mode.setAccessibilityLabel("Расположение окна")
        columns.setAccessibilityLabel("Количество колонок")
        rows.setAccessibilityLabel("Видимых строк")
        for button in [mode, columns, rows] {
            button.font = .systemFont(ofSize: 12)
            button.target = self; button.action = #selector(changed)
            button.menu?.delegate = self
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Расположение"), mode],
            [NSTextField(labelWithString: "Колонки"), columns],
            [NSTextField(labelWithString: "Видимых строк"), rows]
        ])
        grid.columnSpacing = 12; grid.rowSpacing = 8
        grid.xPlacement = .fill; grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .leading
        root.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true

        sidebar.state = appearance.sidebarVisible ? .on : .off
        sidebar.font = .systemFont(ofSize: 12)
        sidebar.target = self; sidebar.action = #selector(changed)
        root.addArrangedSubview(sidebar)
        let explanation = NSTextField(wrappingLabelWithString: "Одна колонка — список, несколько — сетка. Число строк задаёт высоту карточек. В небольшом окне их будет меньше; остальные доступны при прокрутке.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 316
        root.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let done = NSButton(title: "Готово", target: self, action: #selector(finish))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, done])
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        view = root
    }

    func focusInitialControl() { view.window?.makeFirstResponder(mode) }
    func menuWillOpen(_ menu: NSMenu) { isTrackingMenu = true }
    func menuDidClose(_ menu: NSMenu) { isTrackingMenu = false }

    @objc private func changed() {
        let previous = appearance
        let modes = HistoryAppearance.Mode.allCases
        if modes.indices.contains(mode.indexOfSelectedItem) { appearance.mode = modes[mode.indexOfSelectedItem] }
        appearance.columns = columns.indexOfSelectedItem + 1
        appearance.visibleRows = rows.indexOfSelectedItem + 3
        appearance.sidebarVisible = sidebar.state == .on
        if appearance != previous { onChange?(appearance) }
    }
    @objc private func finish() { onDone?() }
}
