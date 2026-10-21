import AppKit
import BufferaLocalization

enum InterfaceTheme: String, CaseIterable {
    case system, light, dark

    static let key = "interfaceTheme"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    func save(to defaults: UserDefaults = .standard) {
        if self == .system { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(rawValue, forKey: Self.key) }
    }

    var title: String {
        switch self {
        case .system: return L10n.text("Системная")
        case .light: return L10n.text("Светлая")
        case .dark: return L10n.text("Тёмная")
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
