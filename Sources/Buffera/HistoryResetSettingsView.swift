import AppKit
import BufferaLocalization

final class HistoryResetSettingsView: NSStackView, NSTextFieldDelegate {
    private let defaults: UserDefaults
    private let enabled = NSButton(checkboxWithTitle: L10n.text("Сбрасывать состояние окна"), target: nil, action: nil)
    private let immediately = NSButton(radioButtonWithTitle: L10n.text("Сразу после закрытия"), target: nil, action: nil)
    private let afterDelay = NSButton(radioButtonWithTitle: L10n.text("Через"), target: nil, action: nil)
    private let minutes = NSTextField(string: "1")
    private let stepper = NSStepper()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        enabled.identifier = NSUserInterfaceItemIdentifier("settings.historyReset.enabled")
        enabled.font = .systemFont(ofSize: 12)
        immediately.identifier = NSUserInterfaceItemIdentifier("settings.historyReset.immediately")
        afterDelay.identifier = NSUserInterfaceItemIdentifier("settings.historyReset.afterDelay")
        immediately.target = self; immediately.action = #selector(selectTiming(_:))
        afterDelay.target = self; afterDelay.action = #selector(selectTiming(_:))
        immediately.font = .systemFont(ofSize: 12); afterDelay.font = .systemFont(ofSize: 12)
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
        let delay = NSStackView(views: [minutes, stepper,
                                      NSTextField(labelWithString: L10n.text("мин. после закрытия"))])
        delay.orientation = .horizontal; delay.alignment = .centerY; delay.spacing = 8
        // Radio buttons share a parent and action for native keyboard grouping.
        let modes = NSView()
        for control in [immediately, afterDelay, delay] {
            control.translatesAutoresizingMaskIntoConstraints = false
            modes.addSubview(control)
        }
        NSLayoutConstraint.activate([
            immediately.leadingAnchor.constraint(equalTo: modes.leadingAnchor, constant: 18),
            immediately.topAnchor.constraint(equalTo: modes.topAnchor),
            immediately.trailingAnchor.constraint(lessThanOrEqualTo: modes.trailingAnchor),
            afterDelay.leadingAnchor.constraint(equalTo: immediately.leadingAnchor),
            afterDelay.centerYAnchor.constraint(equalTo: delay.centerYAnchor),
            delay.leadingAnchor.constraint(equalTo: afterDelay.trailingAnchor, constant: 8),
            delay.trailingAnchor.constraint(lessThanOrEqualTo: modes.trailingAnchor),
            delay.topAnchor.constraint(equalTo: immediately.bottomAnchor, constant: 6),
            delay.bottomAnchor.constraint(equalTo: modes.bottomAnchor)
        ])
        let note = NSTextField(wrappingLabelWithString: L10n.text("Автоматический сброс интерфейса в дефолтное состояние при следующем открытии (очистить поиск и фильтры, выйти из избранного)."))
        note.identifier = NSUserInterfaceItemIdentifier("settings.historyReset.note")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        for child in [enabled, modes, note] { addArrangedSubview(child) }
        modes.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let value = HistoryResetPreferences.load(from: defaults)
        enabled.state = value.isEnabled ? .on : .off
        immediately.state = value.timing == .immediately ? .on : .off
        afterDelay.state = value.timing == .afterDelay ? .on : .off
        immediately.isEnabled = value.isEnabled; afterDelay.isEnabled = value.isEnabled
        minutes.integerValue = value.minutes; stepper.integerValue = value.minutes
        minutes.isEnabled = value.isEnabled && value.timing == .afterDelay
        stepper.isEnabled = minutes.isEnabled
    }

    @objc private func toggleEnabled() {
        let value = HistoryResetPreferences.load(from: defaults)
        HistoryResetPreferences(isEnabled: enabled.state == .on, minutes: value.minutes, timing: value.timing).save(to: defaults)
        refresh()
    }

    @objc private func selectTiming(_ sender: NSButton) {
        let value = HistoryResetPreferences.load(from: defaults)
        let timing: HistoryResetPreferences.Timing = sender === immediately ? .immediately : .afterDelay
        HistoryResetPreferences(isEnabled: value.isEnabled, minutes: value.minutes, timing: timing).save(to: defaults)
        refresh()
    }

    @objc private func stepMinutes() { saveMinutes(stepper.integerValue) }

    func controlTextDidEndEditing(_ notification: Notification) { saveMinutes(minutes.integerValue) }

    private func saveMinutes(_ value: Int) {
        let current = HistoryResetPreferences.load(from: defaults)
        HistoryResetPreferences(isEnabled: current.isEnabled, minutes: value, timing: current.timing).save(to: defaults)
        refresh()
    }
}
