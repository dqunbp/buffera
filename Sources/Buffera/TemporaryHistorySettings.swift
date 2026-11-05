import AppKit
import BufferaLocalization

enum TemporaryHistoryPreferences {
    static let preferenceKey = "saveTemporaryClips"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preferenceKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: preferenceKey)
    }
}

final class TemporaryHistorySettingsView: NSStackView {
    var onChange: ((Bool) -> Void)?
    private let defaults: UserDefaults
    private let enabled = NSButton(checkboxWithTitle: L10n.text("Сохранять временные записи"), target: nil, action: nil)

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        enabled.target = self; enabled.action = #selector(changed)
        enabled.font = .systemFont(ofSize: 12)
        enabled.identifier = NSUserInterfaceItemIdentifier("settings.saveTemporaryClips")
        let note = NSTextField(wrappingLabelWithString: L10n.text("Сохранять также записи, которые приложения помечают как временные или автоматически созданные. Например, при диктовке и автоматической вставке текста"))
        note.identifier = NSUserInterfaceItemIdentifier("settings.saveTemporaryClips.note")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        for child in [enabled, note] { addArrangedSubview(child) }
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() { enabled.state = TemporaryHistoryPreferences.load(from: defaults) ? .on : .off }

    @objc private func changed() {
        let value = enabled.state == .on
        guard value != TemporaryHistoryPreferences.load(from: defaults) else { return }
        TemporaryHistoryPreferences.save(value, to: defaults)
        onChange?(value)
    }
}
