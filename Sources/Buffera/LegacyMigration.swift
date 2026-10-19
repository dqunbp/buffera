import Foundation

/// One-time identity migration, completed before any history or settings are opened.
enum LegacyMigration {
    static let previousAppName = "Bufera"
    static let previousBundleIdentifier = "local.bufera.app"
    static let bundleIdentifier = "local.buffera.app"
    private static let currentAppName = "Buffera"
    private static let preferencesMarker = "migration.legacyIdentity.completed"

    static func prepareHistory(in support: URL, fileManager: FileManager = .default) throws -> URL {
        let previous = support.appendingPathComponent(previousAppName, isDirectory: true)
        let current = support.appendingPathComponent(currentAppName, isDirectory: true)
        let previousExists = try isRealDirectory(previous, fileManager: fileManager)
        let currentExists = try isRealDirectory(current, fileManager: fileManager)
        guard !previousExists || !currentExists else { throw MigrationError.conflictingHistories }
        if previousExists {
            // Keep the database, WAL, backups and explicit legacy exports together.
            // Both names share a parent; moveItem refuses an existing destination.
            try fileManager.moveItem(at: previous, to: current)
        }
        return current
    }

    static func migratePreferences(defaults: UserDefaults = .standard,
                                   legacyDomain: String = previousBundleIdentifier,
                                   currentDomain: String = bundleIdentifier) throws {
        let current = defaults.persistentDomain(forName: currentDomain) ?? [:]
        guard current[preferencesMarker] as? Bool != true else { return }
        let previous = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        var merged = current
        let unchanged = ["hasLaunched", "maxCount", "maxBytes", "historyAppearance.mode",
                         "historyAppearance.columns", "historyAppearance.visibleRows",
                         "historyAppearance.sidebarVisible", "historyAppearance.sideWidth"]
        let renamed = [
            "NSWindow Frame \(previousAppName)History": "NSWindow Frame \(currentAppName)History",
            "NSWindow Frame \(previousAppName)SettingsWindow": "NSWindow Frame \(currentAppName)SettingsWindow",
            "NSStatusItem Preferred Position \(previousAppName)Clipboard": "NSStatusItem Preferred Position \(currentAppName)Clipboard",
            "NSStatusItem Visible \(previousAppName)Clipboard": "NSStatusItem Visible \(currentAppName)Clipboard"
        ]
        for key in unchanged where merged[key] == nil { merged[key] = previous[key] }
        for (oldKey, newKey) in renamed where merged[newKey] == nil { merged[newKey] = previous[oldKey] }
        // Publish the values and completion marker together, never an early marker.
        merged[preferencesMarker] = true
        defaults.setPersistentDomain(merged, forName: currentDomain)
        guard defaults.synchronize() else {
            defaults.setPersistentDomain(current, forName: currentDomain)
            throw MigrationError.preferencesWriteFailed
        }
    }

    private static func isRealDirectory(_ url: URL, fileManager: FileManager) throws -> Bool {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MigrationError.invalidDirectory(url)
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private enum MigrationError: LocalizedError {
        case conflictingHistories, invalidDirectory(URL), preferencesWriteFailed

        var errorDescription: String? {
            switch self {
            case .conflictingHistories:
                return "Найдены две папки истории: \(previousAppName) и \(currentAppName). Они сохранены без изменений; перед запуском нужно выбрать, какую историю использовать."
            case .invalidDirectory(let url):
                return "Не удалось перенести историю: \(url.path) должен быть обычной папкой, а не файлом или ссылкой."
            case .preferencesWriteFailed:
                return "Не удалось сохранить перенесённые настройки \(currentAppName). Повторите запуск."
            }
        }
    }
}
