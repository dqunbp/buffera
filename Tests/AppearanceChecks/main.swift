import Foundation

// swiftc -module-cache-path .build/ModuleCache Sources/Bufera/HistoryAppearance.swift \
//   Tests/AppearanceChecks/main.swift -o .build/appearance-checks
// .build/appearance-checks

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw NSError(domain: "AppearanceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

let suite = "local.bufera.appearance-checks.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
try check(HistoryAppearance.load(from: defaults) == HistoryAppearance(), "Missing settings must use the default list layout")

defaults.set(50_000, forKey: "maxCount")
defaults.set("Unrelated setting", forKey: "fixture.unrelated")
for mode in HistoryAppearance.Mode.allCases {
    let original = HistoryAppearance(mode: mode, columns: 3, visibleRows: 9, sidebarVisible: false)
    original.save(to: defaults)
    try check(HistoryAppearance.load(from: defaults) == original, "Every mode and all layout fields must round-trip")
}
try check(defaults.integer(forKey: "maxCount") == 50_000 && defaults.string(forKey: "fixture.unrelated") == "Unrelated setting",
          "Saving appearance must preserve other defaults")

defaults.set("future-mode", forKey: "historyAppearance.mode")
defaults.set(-50, forKey: "historyAppearance.columns")
defaults.set(999, forKey: "historyAppearance.visibleRows")
let bounded = HistoryAppearance.load(from: defaults)
try check(bounded.mode == .floating && bounded.columns == 1 && bounded.visibleRows == 12,
          "Unknown modes must fall back, and out-of-range persisted counts must clamp")
defaults.set(Int.max, forKey: "historyAppearance.columns")
defaults.set(Int.min, forKey: "historyAppearance.visibleRows")
let extremes = HistoryAppearance.load(from: defaults)
try check(extremes.columns == 4 && extremes.visibleRows == 3, "Extreme integer settings must clamp without overflow")

defaults.set(["invalid"], forKey: "historyAppearance.mode")
defaults.set("three", forKey: "historyAppearance.columns")
defaults.set(true, forKey: "historyAppearance.visibleRows")
defaults.set("false", forKey: "historyAppearance.sidebarVisible")
try check(HistoryAppearance.load(from: defaults) == HistoryAppearance(), "Malformed types must use defaults rather than coerce values")
defaults.set(2.5, forKey: "historyAppearance.columns")
defaults.set(7.5, forKey: "historyAppearance.visibleRows")
try check(HistoryAppearance.load(from: defaults) == HistoryAppearance(), "Fractional counts must not silently truncate")

var assigned = HistoryAppearance(mode: .right, columns: -1, visibleRows: 100, sidebarVisible: false)
try check(assigned.columns == 1 && assigned.visibleRows == 12, "Constructed settings must be bounded")
assigned.columns = 500; assigned.visibleRows = -1
try check(assigned.columns == 4 && assigned.visibleRows == 3, "Assigned counts must remain bounded")
assigned.save(to: defaults)
try check(HistoryAppearance.load(from: defaults) == assigned, "Clamped settings must persist consistently")
print("PASS: appearance defaults, modes, round-trip, bounds, malformed types and unrelated preferences")
