import AppKit
import BufferaLocalization

final class HistoryResetSettingsView: NSStackView, NSTextFieldDelegate {
    private let defaults: UserDefaults
    private let enabled = NSButton(checkboxWithTitle: L10n.text("Сбрасывать поиск и фильтры"), target: nil, action: nil)
    private let minutes = NSTextField(string: "1")
    private let stepper = NSStepper()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        enabled.identifier = NSUserInterfaceItemIdentifier("settings.historyReset.enabled")
        enabled.font = .systemFont(ofSize: 12)
        minutes.identifier = NSUserInterfaceItemIdentifier("settings.historyReset.minutes")
        minutes.setAccessibilityLabel(L10n.text("Время до сброса, минут"))
        minutes.delegate = self
        minutes.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let formatter = NumberFormatter()
        formatter.numberStyle = .none; formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: HistoryResetPreferences.minuteRange.lowerBound)
        formatter.maximum = NSNumber(value: HistoryResetPreferences.minuteRange.upperBound)
        minutes.formatter = formatter
        stepper.minValue = Double(HistoryResetPreferences.minuteRange.lowerBound)
        stepper.maxValue = Double(HistoryResetPreferences.minuteRange.upperBound)
        stepper.increment = 1; stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(stepMinutes)
        stepper.identifier = NSUserInterfaceItemIdentifier("settings.historyReset.stepper")
        stepper.setAccessibilityLabel(L10n.text("Время до сброса, минут"))
        let delay = NSStackView(views: [NSTextField(labelWithString: L10n.text("Через")), minutes, stepper,
                                      NSTextField(labelWithString: L10n.text("мин. после закрытия"))])
        delay.orientation = .horizontal; delay.alignment = .centerY; delay.spacing = 8
        let note = NSTextField(wrappingLabelWithString: L10n.text("При следующем открытии — пустой поиск, все записи без фильтров и выбор первой записи. Открытое окно не сбрасывается. Сохранённые записи не удаляются."))
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        for child in [enabled, delay, note] { addArrangedSubview(child) }
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let value = HistoryResetPreferences.load(from: defaults)
        enabled.state = value.isEnabled ? .on : .off
        minutes.integerValue = value.minutes; stepper.integerValue = value.minutes
        minutes.isEnabled = value.isEnabled; stepper.isEnabled = value.isEnabled
    }

    @objc private func toggleEnabled() {
        let value = HistoryResetPreferences.load(from: defaults)
        HistoryResetPreferences(isEnabled: enabled.state == .on, minutes: value.minutes).save(to: defaults)
        refresh()
    }

    @objc private func stepMinutes() { saveMinutes(stepper.integerValue) }

    func controlTextDidEndEditing(_ notification: Notification) { saveMinutes(minutes.integerValue) }

    private func saveMinutes(_ value: Int) {
        HistoryResetPreferences(isEnabled: enabled.state == .on, minutes: value).save(to: defaults)
        refresh()
    }
}
