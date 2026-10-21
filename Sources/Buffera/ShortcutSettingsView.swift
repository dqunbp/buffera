import AppKit
import BufferaLocalization

final class ShortcutSettingsView: NSStackView {
    var onApply: ((ShortcutPreferences) throws -> Void)?
    private let base = NSPopUpButton()
    private let nextLetter = NSPopUpButton()
    private let previousLetter = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")

    init(value: ShortcutPreferences) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        base.addItems(withTitles: ShortcutPreferences.Base.allCases.map(\.title))
        for popup in [nextLetter, previousLetter] { popup.addItems(withTitles: ShortcutPreferences.letters) }
        let fields: [(String, String, NSPopUpButton)] = [
            (L10n.text("Базовые клавиши"), "base", base),
            (L10n.text("Открыть / следующая запись"), "next", nextLetter),
            (L10n.text("Предыдущая запись"), "previous", previousLetter)
        ]
        for (title, id, popup) in fields {
            popup.identifier = .init("shortcuts." + id)
            popup.setAccessibilityLabel(title)
            popup.widthAnchor.constraint(equalToConstant: 110).isActive = true
            popup.target = self; popup.action = #selector(edit)
        }
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: $0.0), $0.2] })
        grid.rowSpacing = 8; grid.columnSpacing = 18
        let apply = NSButton(title: L10n.text("Применить"), target: self, action: #selector(applyDraft))
        apply.identifier = .init("shortcuts.apply"); apply.bezelStyle = .rounded
        let reset = NSButton(title: L10n.text("По умолчанию"), target: self, action: #selector(reset))
        reset.identifier = .init("shortcuts.reset"); reset.bezelStyle = .rounded
        let buttons = NSStackView(views: [apply, reset]); buttons.spacing = 10
        let lettersNote = NSTextField(wrappingLabelWithString: L10n.text("Буквы A–Z обозначают клавиши латинской раскладки; сочетания работают и в других раскладках."))
        for field in [lettersNote, status, hint] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
        }
        status.identifier = .init("shortcuts.status")
        hint.identifier = .init("shortcuts.hint")
        for view in [grid, buttons, lettersNote, status, hint] { addArrangedSubview(view) }
        for view in [lettersNote, status, hint] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        refresh(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(_ value: ShortcutPreferences) {
        base.selectItem(at: ShortcutPreferences.Base.allCases.firstIndex(of: value.base)!)
        nextLetter.selectItem(withTitle: value.next)
        previousLetter.selectItem(withTitle: value.previous)
        status.stringValue = ""; status.isHidden = true
        hint.stringValue = value.usageHint
    }

    @objc private func edit() {
        status.stringValue = L10n.text("Нажмите «Применить», чтобы сохранить новые сочетания.")
        status.textColor = .secondaryLabelColor; status.isHidden = false
    }

    @objc private func applyDraft() {
        apply(ShortcutPreferences(base: ShortcutPreferences.Base.allCases[base.indexOfSelectedItem],
                                  next: nextLetter.titleOfSelectedItem ?? "", previous: previousLetter.titleOfSelectedItem ?? ""))
    }

    @objc private func reset() { apply(.defaults) }

    private func apply(_ value: ShortcutPreferences) {
        do {
            try value.validate()
            guard let onApply else { throw ShortcutPreferenceError.unavailable }
            try onApply(value)
            refresh(value)
            status.stringValue = L10n.text("Сохранено: \(value.nextTitle) и \(value.previousTitle).")
            status.textColor = .secondaryLabelColor
        } catch {
            status.stringValue = error.localizedDescription
            status.textColor = .systemRed
        }
        status.isHidden = false
    }
}
