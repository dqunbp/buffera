import AppKit
import BufferaCore
import BufferaLocalization

enum SecretHistoryMode: String, CaseIterable {
    case skip, encrypted
    static let preferenceKey = "secretHistoryMode"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .skip
    }
    var title: String {
        switch self {
        case .skip: return L10n.text("Не сохранять секреты")
        case .encrypted: return L10n.text("Сохранять секреты зашифрованными")
        }
    }
}

final class SecretHistorySettingsView: NSStackView {
    typealias Apply = (SecretHistoryMode, @escaping (Result<Void, Error>) -> Void) -> Void
    var onApply: Apply?
    private let defaults: UserDefaults
    private let picker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var applying = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        let title = NSTextField(labelWithString: L10n.text("Секреты в истории"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        picker.addItems(withTitles: SecretHistoryMode.allCases.map(\.title))
        picker.target = self; picker.action = #selector(changed)
        picker.identifier = NSUserInterfaceItemIdentifier("settings.secretHistoryMode")
        picker.setAccessibilityLabel(title.stringValue)
        let note = NSTextField(wrappingLabelWithString: L10n.text("Секретами считаются записи с отметкой конфиденциальности от приложения. Остальные записи хранятся как обычно. Сохранённые секреты доступны только в Buffera; MCP не получает их содержимое."))
        let retention = NSTextField(wrappingLabelWithString: L10n.text("Режим применяется к новым копированиям. Уже сохранённые секреты остаются зашифрованными. Команда «Скрыть» также шифрует запись."))
        for label in [note, retention, status] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        for child in [title, picker, note, retention, status] { addArrangedSubview(child) }
        for label in [note, retention, status] { label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        guard !applying else { return }
        picker.selectItem(at: SecretHistoryMode.allCases.firstIndex(of: .load(from: defaults)) ?? 0)
    }

    @objc private func changed() {
        guard SecretHistoryMode.allCases.indices.contains(picker.indexOfSelectedItem) else { return }
        let mode = SecretHistoryMode.allCases[picker.indexOfSelectedItem]
        guard let onApply else { refresh(); return }
        applying = true; picker.isEnabled = false
        status.stringValue = L10n.text("Применяем настройку…")
        onApply(mode) { [weak self] result in
            guard let self else { return }
            self.applying = false; self.picker.isEnabled = true
            switch result {
            case .success:
                self.defaults.set(mode.rawValue, forKey: SecretHistoryMode.preferenceKey)
                self.status.stringValue = ""
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
            self.refresh()
        }
    }
}
