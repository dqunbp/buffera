import Foundation

// swiftc -module-cache-path .build/ModuleCache Sources/Buffera/HistoryLimits.swift Tests/SettingsChecks/main.swift -o .build/settings-checks/checks
// .build/settings-checks/checks
// Isolated defaults only: this does not open UI or touch the real application's preferences.
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
    print("PASS", message)
}

let suite = "Buffera.SettingsChecks.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(HistoryLimits.load(from: defaults) == HistoryLimits(maxCount: 50_000, maxBytes: 5_000_000_000),
      "absent preferences keep existing defaults")
for (count, bytes) in zip(HistoryLimits.countChoices, HistoryLimits.byteChoices) {
    let expected = HistoryLimits(maxCount: count, maxBytes: bytes)
    expected.save(to: defaults)
    check(HistoryLimits.load(from: defaults) == expected, "each settings choice round-trips through existing keys")
}
let custom = HistoryLimits(maxCount: 42_000, maxBytes: 3_000_000_000)
custom.save(to: defaults)
check(HistoryLimits.load(from: defaults) == custom, "valid custom values survive settings reload")
check(defaults.integer(forKey: "maxCount") == 42_000 && defaults.integer(forKey: "maxBytes") == 3_000_000_000,
      "settings keep legacy preference keys")
for invalid: Any in [true, "12345", 1.5, Double.infinity, Double.nan] {
    defaults.set(invalid, forKey: "maxCount")
    defaults.set(invalid, forKey: "maxBytes")
    check(HistoryLimits.load(from: defaults) == HistoryLimits(), "malformed numeric preferences use safe defaults")
}
defaults.set(-10, forKey: "maxCount")
defaults.set(-10, forKey: "maxBytes")
check(HistoryLimits.load(from: defaults) == HistoryLimits(maxCount: 10_000, maxBytes: 1_000_000_000),
      "negative limits clamp to the smallest supported value")
defaults.set(Int.max, forKey: "maxCount")
defaults.set(Int.max, forKey: "maxBytes")
let extreme = HistoryLimits.load(from: defaults)
check(extreme.maxCount >= 10_000 && extreme.maxCount <= 100_000 && extreme.maxBytes >= 1_000_000_000 && extreme.maxBytes <= 20_000_000_000,
      "extreme persisted values cannot overflow or escape bounds")
var changing = HistoryLimits()
changing.maxCount = .max; changing.maxBytes = .min
check(changing.maxCount == 100_000 && changing.maxBytes == 1_000_000_000, "mutations retain bounded limits")
print("PASS \(checks) settings persistence checks")
