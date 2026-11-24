import AppKit
import Carbon
import BufferaLocalization

final class ShortcutSettingsView: NSStackView {
    private enum Command: String {
        case next, previous, pause, skipNext

        var canClear: Bool { self == .pause || self == .skipNext }
    }

    private struct Row {
        let title: String
        let value: NSTextField
        let action: ShortcutCaptureButton
        let clear: NSButton?
    }

    var onApply: ((ShortcutPreferences) throws -> Void)?
    private var applied: ShortcutPreferences
    private var draft: ShortcutPreferences
    private var capturing: Command?
    private var rows: [Command: Row] = [:]
    private let applyButton = NSButton()
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
            let value = NSTextField(labelWithString: "")
            value.identifier = .init("shortcuts.value." + command.rawValue)
            value.alignment = .right
            let button = ShortcutCaptureButton(title: "", target: self, action: #selector(beginCapture(_:)))
            button.identifier = .init("shortcuts." + command.rawValue)
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(equalToConstant: 176).isActive = true
            button.onResignFocus = { [weak self] in
                guard let self, self.capturing == command else { return }
                self.cancelCapture()
            }
            // The native focus ring needs space inside the stack's arranged view.
            let focusArea = NSView()
            focusArea.clipsToBounds = false
            button.translatesAutoresizingMaskIntoConstraints = false
            focusArea.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: focusArea.topAnchor, constant: 6),
                button.bottomAnchor.constraint(equalTo: focusArea.bottomAnchor, constant: -6),
                button.leadingAnchor.constraint(equalTo: focusArea.leadingAnchor, constant: 5),
                button.trailingAnchor.constraint(equalTo: focusArea.trailingAnchor, constant: -5)
            ])
            let actions = NSStackView(views: [focusArea])
            actions.clipsToBounds = false
            actions.spacing = 6
            var clearAction: NSButton?
            if command.canClear {
                let clearTitle = L10n.text("Снять назначение")
                let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)!,
                                     target: self, action: #selector(clearBinding(_:)))
                clear.identifier = .init("shortcuts.clear." + command.rawValue)
                clear.setAccessibilityLabel(clearTitle + " — " + title)
                clear.toolTip = clearTitle
                clear.bezelStyle = .regularSquare
                clear.isBordered = false
                clearAction = clear
                actions.addArrangedSubview(clear)
            }
            rows[command] = Row(title: title, value: value, action: button, clear: clearAction)
            return [NSTextField(labelWithString: title), value, actions]
        })
        grid.rowSpacing = 2
        grid.columnSpacing = 14
        grid.rowAlignment = .none
        grid.yPlacement = .center
        grid.column(at: 1).xPlacement = .trailing
        grid.clipsToBounds = false
        applyButton.title = L10n.text("Применить")
        applyButton.target = self
        applyButton.action = #selector(applyDraft)
        applyButton.identifier = .init("shortcuts.apply")
        applyButton.bezelStyle = .rounded
        let reset = NSButton(title: L10n.text("Сбросить сочетания"), target: self, action: #selector(reset))
        reset.identifier = .init("shortcuts.reset")
        reset.bezelStyle = .rounded
        let actions = NSStackView(views: [applyButton, reset])
        actions.spacing = 10
        let instruction = NSTextField(wrappingLabelWithString: L10n.text("Нажмите «Изменить» или «Назначить» и введите сочетание клавиш."))
        instruction.identifier = .init("shortcuts.instruction")
        instruction.font = .systemFont(ofSize: 12)
        instruction.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString: L10n.text("Модификаторы общие для всех команд. Сочетания привязаны к физическим клавишам."))
        for field in [note, status, hint] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
        }
        status.identifier = .init("shortcuts.status")
        hint.identifier = .init("shortcuts.hint")
        for view in [instruction, grid, actions, note, status, hint] { addArrangedSubview(view) }
        for view in [instruction, note, status, hint] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        refresh(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(_ value: ShortcutPreferences) {
        applied = value
        draft = value
        capturing = nil
        showDraft()
    }

    @objc private func beginCapture(_ sender: ShortcutCaptureButton) {
        guard let command = rows.first(where: { $0.value.action === sender })?.key else { return }
        if capturing == command {
            cancelCapture()
        } else if sender.window?.makeFirstResponder(sender) == true {
            capturing = command
            showDraft()
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
        guard let command = capturing, let button = rows[command]?.action,
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
        if sender === rows[.pause]?.clear { draft.pause = nil }
        if sender === rows[.skipNext]?.clear { draft.skipNext = nil }
        capturing = nil
        showDraft()
    }

    private func showDraft() {
        updateRows()
        do {
            try draft.validate()
            applyButton.isEnabled = true
            hint.stringValue = draft.usageHint
            hint.isHidden = false
            let pending = capturing == nil && draft != applied
            showStatus(pending ? L10n.text("Нажмите «Применить», чтобы сохранить новые сочетания.") : "")
        } catch {
            applyButton.isEnabled = false
            hint.isHidden = true
            showStatus(error.localizedDescription, error: true)
        }
    }

    private func updateRows() {
        let keys: [Command: ShortcutKey] = [
            .next: draft.next, .previous: draft.previous, .pause: draft.pause, .skipNext: draft.skipNext
        ].compactMapValues { $0 }
        for (command, row) in rows {
            let shortcut = keys[command].map { draft.title(for: $0) }
            let value = shortcut ?? L10n.text("Не назначено")
            row.value.stringValue = value
            row.value.textColor = shortcut == nil ? .secondaryLabelColor : .labelColor
            let title = command == capturing ? L10n.text("Нажмите сочетание…")
                : shortcut == nil ? L10n.text("Назначить") : L10n.text("Изменить")
            row.action.title = title
            row.action.setAccessibilityLabel(title + " — " + row.title)
            row.action.setAccessibilityValue(value)
            row.clear?.isEnabled = shortcut != nil
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
