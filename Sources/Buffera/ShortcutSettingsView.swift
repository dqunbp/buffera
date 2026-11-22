import AppKit
import Carbon
import BufferaLocalization

final class ShortcutSettingsView: NSStackView {
    private enum Command: String {
        case next, previous, pause, skipNext

        var canClear: Bool { self == .pause || self == .skipNext }
    }

    var onApply: ((ShortcutPreferences) throws -> Void)?
    private var applied: ShortcutPreferences
    private var draft: ShortcutPreferences
    private var capturing: Command?
    private var buttons: [Command: ShortcutCaptureButton] = [:]
    private var clearButtons: [Command: NSButton] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")

    init(value: ShortcutPreferences) {
        applied = value
        draft = value
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        let fields: [(Command, String)] = [
            (.next, L10n.text("Открыть / следующая запись")),
            (.previous, L10n.text("Предыдущая запись")),
            (.pause, L10n.text("Приостановить / возобновить запись")),
            (.skipNext, L10n.text("Пропустить следующее копирование"))
        ]
        let grid = NSGridView(views: fields.map { command, title in
            let button = ShortcutCaptureButton(title: "", target: self, action: #selector(beginCapture(_:)))
            button.identifier = .init("shortcuts." + command.rawValue)
            button.setAccessibilityLabel(title)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 176).isActive = true
            button.onResignFocus = { [weak self] in
                guard let self, self.capturing == command else { return }
                self.cancelCapture()
            }
            buttons[command] = button
            let row = NSStackView(views: [button])
            row.spacing = 6
            if command.canClear {
                let clearTitle = L10n.text("Снять назначение")
                let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)!,
                                     target: self, action: #selector(clearBinding(_:)))
                clear.identifier = .init("shortcuts.clear." + command.rawValue)
                clear.setAccessibilityLabel(clearTitle + " — " + title)
                clear.toolTip = clearTitle
                clear.bezelStyle = .regularSquare
                clear.isBordered = false
                clearButtons[command] = clear
                row.addArrangedSubview(clear)
            }
            return [NSTextField(labelWithString: title), row]
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        let apply = NSButton(title: L10n.text("Применить"), target: self, action: #selector(applyDraft))
        apply.identifier = .init("shortcuts.apply")
        apply.bezelStyle = .rounded
        let reset = NSButton(title: L10n.text("Сбросить сочетания"), target: self, action: #selector(reset))
        reset.identifier = .init("shortcuts.reset")
        reset.bezelStyle = .rounded
        let actions = NSStackView(views: [apply, reset])
        actions.spacing = 10
        let note = NSTextField(wrappingLabelWithString: L10n.text("Модификаторы общие для всех команд. Сочетания привязаны к физическим клавишам."))
        for field in [note, status, hint] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
        }
        status.identifier = .init("shortcuts.status")
        hint.identifier = .init("shortcuts.hint")
        for view in [grid, actions, note, status, hint] { addArrangedSubview(view) }
        for view in [note, status, hint] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        refresh(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(_ value: ShortcutPreferences) {
        applied = value
        draft = value
        capturing = nil
        updateButtons()
        showStatus("")
        hint.stringValue = value.usageHint
    }

    @objc private func beginCapture(_ sender: ShortcutCaptureButton) {
        guard let command = buttons.first(where: { $0.value === sender })?.key else { return }
        if capturing == command {
            cancelCapture()
        } else if sender.window?.makeFirstResponder(sender) == true {
            capturing = command
            updateButtons()
            showStatus("")
        }
    }

    func cancelCapture() {
        guard capturing != nil else { return }
        capturing = nil
        showDraft()
    }

    func capture(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, capturing != nil else { return false }
        if event.keyCode == kVK_Tab,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            cancelCapture()
            return false
        }
        return event.isARepeat || capture(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    func capture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let command = capturing, let button = buttons[command],
              !button.isHiddenOrHasHiddenAncestor, button.window?.firstResponder === button else { return false }
        if keyCode == kVK_Escape {
            cancelCapture()
            return true
        }
        guard let base = ShortcutPreferences.Base(modifiers: modifiers) else {
            showStatus(L10n.text("Используйте ⌃, ⌘⌥, ⌃⌥, ⌃⇧, ⌘⇧ или ⌃⌘⌥."), error: true)
            return true
        }
        guard let key = ShortcutKey(code: keyCode) else {
            showStatus(L10n.text("Выберите букву, цифру или клавишу с символом."), error: true)
            return true
        }
        draft.base = base
        switch command {
        case .next: draft.next = key
        case .previous: draft.previous = key
        case .pause: draft.pause = key
        case .skipNext: draft.skipNext = key
        }
        capturing = nil
        showDraft()
        return true
    }

    @objc private func clearBinding(_ sender: NSButton) {
        if sender === clearButtons[.pause] { draft.pause = nil }
        if sender === clearButtons[.skipNext] { draft.skipNext = nil }
        capturing = nil
        showDraft()
    }

    private func showDraft() {
        updateButtons()
        showStatus(draft == applied ? "" : L10n.text("Нажмите «Применить», чтобы сохранить новые сочетания."))
    }

    private func updateButtons() {
        let keys: [Command: ShortcutKey] = [
            .next: draft.next, .previous: draft.previous, .pause: draft.pause, .skipNext: draft.skipNext
        ].compactMapValues { $0 }
        for (command, button) in buttons {
            let title = command == capturing ? L10n.text("Нажмите сочетание…")
                : keys[command].map { draft.title(for: $0) } ?? L10n.text("Не назначено")
            button.title = title
            button.setAccessibilityValue(title)
            clearButtons[command]?.isEnabled = keys[command] != nil
        }
    }

    private func showStatus(_ text: String, error: Bool = false) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
        status.isHidden = text.isEmpty
    }

    @objc private func applyDraft() { apply(draft) }
    @objc private func reset() { apply(.defaults) }

    private func apply(_ value: ShortcutPreferences) {
        cancelCapture()
        do {
            try value.validate()
            guard let onApply else { throw ShortcutPreferenceError.unavailable }
            try onApply(value)
            refresh(value)
            showStatus(L10n.text("Сочетания сохранены."))
        } catch {
            showStatus(error.localizedDescription, error: true)
        }
    }
}

private final class ShortcutCaptureButton: NSButton {
    var onResignFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onResignFocus?()
        return true
    }
}
