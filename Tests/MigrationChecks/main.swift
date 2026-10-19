import Foundation

// swiftc -module-cache-path .build/ModuleCache Sources/Buffera/LegacyMigration.swift Tests/MigrationChecks/main.swift -o .build/migration-checks

private var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "MigrationChecks", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: message]) }
    checks += 1
}

func expectFailure(_ message: String, _ action: () throws -> Void) throws {
    var failed = false
    do { try action() } catch { failed = true }
    try check(failed, message)
}

let manager = FileManager.default
let sandbox = manager.temporaryDirectory.appendingPathComponent("BufferaMigrationChecks-\(UUID().uuidString)", isDirectory: true)
try manager.createDirectory(at: sandbox, withIntermediateDirectories: false)
defer { try? manager.removeItem(at: sandbox) }

func support(_ name: String) throws -> URL {
    let folder = sandbox.appendingPathComponent(name, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

let empty = try support("empty")
let newEmpty = try LegacyMigration.prepareHistory(in: empty)
try check(newEmpty.lastPathComponent == "Buffera", "Fresh history uses the new name")
try check(!manager.fileExists(atPath: newEmpty.path), "HistoryStore remains responsible for creating a fresh database")

let oldSupport = try support("legacy")
let oldFolder = oldSupport.appendingPathComponent(LegacyMigration.previousAppName, isDirectory: true)
try manager.createDirectory(at: oldFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let contents = ["history.sqlite": Data([1, 2]), "history.sqlite-wal": Data([3, 4]), "history.sqlite-shm": Data([5]),
                "Backups/snapshot.sqlite": Data([6]), "Exports/saved.png": Data([7])]
for (name, data) in contents {
    let url = oldFolder.appendingPathComponent(name)
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}
let migrated = try LegacyMigration.prepareHistory(in: oldSupport)
for (name, data) in contents {
    try check(try Data(contentsOf: migrated.appendingPathComponent(name)) == data, "Whole-directory migration preserves \(name)")
}
try check(!manager.fileExists(atPath: oldFolder.path), "The old folder is moved, not duplicated")
try check((try manager.attributesOfItem(atPath: migrated.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700,
          "Migration keeps private directory permissions")
try check(try LegacyMigration.prepareHistory(in: oldSupport) == migrated, "A repeated migration uses the same new history")

let oldEmptySupport = try support("old-empty")
try manager.createDirectory(at: oldEmptySupport.appendingPathComponent(LegacyMigration.previousAppName), withIntermediateDirectories: false)
let movedEmpty = try LegacyMigration.prepareHistory(in: oldEmptySupport)
try check(try manager.contentsOfDirectory(atPath: movedEmpty.path).isEmpty, "An empty legacy folder is moved safely")

let conflictSupport = try support("conflict")
let conflictingOld = conflictSupport.appendingPathComponent(LegacyMigration.previousAppName)
let conflictingNew = conflictSupport.appendingPathComponent("Buffera")
try manager.createDirectory(at: conflictingOld, withIntermediateDirectories: false)
try manager.createDirectory(at: conflictingNew, withIntermediateDirectories: false)
try Data([8]).write(to: conflictingOld.appendingPathComponent("history.sqlite"))
try Data([9]).write(to: conflictingNew.appendingPathComponent("history.sqlite"))
try expectFailure("Two histories must not be merged or overwritten") { _ = try LegacyMigration.prepareHistory(in: conflictSupport) }
try check(try Data(contentsOf: conflictingOld.appendingPathComponent("history.sqlite")) == Data([8]), "Conflict preserves the old history")
try check(try Data(contentsOf: conflictingNew.appendingPathComponent("history.sqlite")) == Data([9]), "Conflict preserves the new history")

for name in [LegacyMigration.previousAppName, "Buffera"] {
    let linkedSupport = try support("link-\(name)")
    let link = linkedSupport.appendingPathComponent(name)
    try manager.createSymbolicLink(at: link, withDestinationURL: migrated)
    try expectFailure("A \(name) directory symlink is refused") { _ = try LegacyMigration.prepareHistory(in: linkedSupport) }
    try check(try manager.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeSymbolicLink, "Refused links are untouched")
    let fileSupport = try support("file-\(name)")
    try Data([10]).write(to: fileSupport.appendingPathComponent(name))
    try expectFailure("A file in place of \(name) directory is refused") { _ = try LegacyMigration.prepareHistory(in: fileSupport) }
}
let danglingSupport = try support("dangling")
try manager.createSymbolicLink(at: danglingSupport.appendingPathComponent(LegacyMigration.previousAppName),
                              withDestinationURL: sandbox.appendingPathComponent("absent"))
try expectFailure("A dangling directory symlink is refused") { _ = try LegacyMigration.prepareHistory(in: danglingSupport) }

let legacyDomain = "local.buffera.migration-checks.old.\(UUID().uuidString)"
let currentDomain = "local.buffera.migration-checks.new.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: currentDomain)!
defer {
    defaults.removePersistentDomain(forName: legacyDomain)
    defaults.removePersistentDomain(forName: currentDomain)
    defaults.synchronize()
}
let oldName = LegacyMigration.previousAppName
let previous: [String: Any] = [
    "hasLaunched": true, "maxCount": 100_000, "maxBytes": 20_000_000_000,
    "historyAppearance.mode": "right", "historyAppearance.columns": 3,
    "historyAppearance.visibleRows": 8, "historyAppearance.sidebarVisible": false,
    "historyAppearance.sideWidth": 523.5,
    "NSWindow Frame \(oldName)History": "10 20 600 700 0 0 1920 1080 ",
    "NSWindow Frame \(oldName)SettingsWindow": "30 40 620 510 0 0 1920 1080 ",
    "NSStatusItem Preferred Position \(oldName)Clipboard": 220,
    "NSStatusItem Visible \(oldName)Clipboard": true,
    "historyAppearance.unrelated": "ignore", "arbitrary": "ignore"
]
defaults.setPersistentDomain(previous, forName: legacyDomain)
defaults.setPersistentDomain(["maxCount": 50_000, "historyAppearance.columns": 2, "existing": "preserved"], forName: currentDomain)
try LegacyMigration.migratePreferences(defaults: defaults, legacyDomain: legacyDomain, currentDomain: currentDomain)
var result = defaults.persistentDomain(forName: currentDomain)!
try check(result["maxCount"] as? Int == 50_000 && result["historyAppearance.columns"] as? Int == 2,
          "New preferences take priority over legacy values")
try check(result["maxBytes"] as? Int == 20_000_000_000 && result["hasLaunched"] as? Bool == true, "History limits and launch state migrate")
try check(result["historyAppearance.mode"] as? String == "right" && result["historyAppearance.sideWidth"] as? Double == 523.5,
          "Appearance and side-panel width migrate")
try check(result["historyAppearance.sidebarVisible"] as? Bool == false && result["historyAppearance.visibleRows"] as? Int == 8,
          "False and integer preference values retain their types")
try check(result["NSWindow Frame BufferaHistory"] as? String == previous["NSWindow Frame \(oldName)History"] as? String,
          "History window geometry is renamed without editing its value")
try check(result["NSWindow Frame BufferaSettingsWindow"] as? String == previous["NSWindow Frame \(oldName)SettingsWindow"] as? String,
          "Settings window geometry is renamed")
try check(result["NSStatusItem Preferred Position BufferaClipboard"] as? Int == 220
          && result["NSStatusItem Visible BufferaClipboard"] as? Bool == true, "Status item position and visibility migrate")
try check(result["NSWindow Frame \(oldName)History"] == nil && result["historyAppearance.unrelated"] == nil && result["arbitrary"] == nil,
          "Only recognized keys are copied under their current names")
try check(result["existing"] as? String == "preserved", "Unrelated current preferences stay untouched")
try check(NSDictionary(dictionary: defaults.persistentDomain(forName: legacyDomain)!) == NSDictionary(dictionary: previous),
          "The legacy domain remains available for rollback")
result.removeValue(forKey: "maxBytes")
defaults.setPersistentDomain(result, forName: currentDomain)
try LegacyMigration.migratePreferences(defaults: defaults, legacyDomain: legacyDomain, currentDomain: currentDomain)
try check(defaults.persistentDomain(forName: currentDomain)!["maxBytes"] == nil, "Completed migration does not resurrect intentionally cleared settings")

// A dictionary left before completion is recoverable; current values still win.
defaults.setPersistentDomain(["maxCount": 10_000, "historyAppearance.columns": "invalid but already stored"], forName: currentDomain)
try LegacyMigration.migratePreferences(defaults: defaults, legacyDomain: legacyDomain, currentDomain: currentDomain)
result = defaults.persistentDomain(forName: currentDomain)!
try check(result["maxBytes"] as? Int == 20_000_000_000 && result["maxCount"] as? Int == 10_000,
          "Retry fills missing keys after an incomplete preference migration")
try check(result["historyAppearance.columns"] as? String == "invalid but already stored", "Preference loaders retain responsibility for malformed stored values")
defaults.removePersistentDomain(forName: legacyDomain)
defaults.removePersistentDomain(forName: currentDomain)
try LegacyMigration.migratePreferences(defaults: defaults, legacyDomain: legacyDomain, currentDomain: currentDomain)
try check(defaults.persistentDomain(forName: currentDomain)?["maxCount"] == nil, "A fresh install has no invented history preferences")

print("PASS: \(checks) identity migration checks")
