import Foundation
import CoreFoundation

struct HistoryAppearance: Equatable {
    enum Mode: String, CaseIterable {
        case floating, left, right

        var title: String {
            switch self {
            case .floating: return "Обычное окно"
            case .left: return "Панель слева"
            case .right: return "Панель справа"
            }
        }
    }

    var mode: Mode
    var columns: Int { didSet { columns = min(4, max(1, columns)) } }
    var visibleRows: Int { didSet { visibleRows = min(12, max(3, visibleRows)) } }
    var sidebarVisible: Bool

    init(mode: Mode = .floating, columns: Int = 1, visibleRows: Int = 6, sidebarVisible: Bool = true) {
        self.mode = mode
        self.columns = min(4, max(1, columns))
        self.visibleRows = min(12, max(3, visibleRows))
        self.sidebarVisible = sidebarVisible
    }

    static func load(from defaults: UserDefaults = .standard) -> HistoryAppearance {
        HistoryAppearance(mode: defaults.string(forKey: Key.mode).flatMap(Mode.init(rawValue:)) ?? .floating,
                          columns: integer(from: defaults, key: Key.columns) ?? 1,
                          visibleRows: integer(from: defaults, key: Key.visibleRows) ?? 6,
                          sidebarVisible: boolean(from: defaults, key: Key.sidebarVisible) ?? true)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        defaults.set(columns, forKey: Key.columns)
        defaults.set(visibleRows, forKey: Key.visibleRows)
        defaults.set(sidebarVisible, forKey: Key.sidebarVisible)
    }

    private enum Key {
        static let mode = "historyAppearance.mode"
        static let columns = "historyAppearance.columns"
        static let visibleRows = "historyAppearance.visibleRows"
        static let sidebarVisible = "historyAppearance.sidebarVisible"
    }

    private static func integer(from defaults: UserDefaults, key: String) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number as? Int
    }

    private static func boolean(from defaults: UserDefaults, key: String) -> Bool? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
