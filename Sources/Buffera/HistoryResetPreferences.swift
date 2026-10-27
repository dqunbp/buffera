import Foundation
import CoreFoundation

struct HistoryResetPreferences: Equatable {
    static let minuteRange = 1...1440
    let isEnabled: Bool
    let minutes: Int

    init(isEnabled: Bool = true, minutes: Int = 1) {
        self.isEnabled = isEnabled
        self.minutes = min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, minutes))
    }

    func shouldReset(closedAt: Date?, now: Date) -> Bool {
        guard isEnabled, let closedAt else { return false }
        return now.timeIntervalSince(closedAt) >= TimeInterval(minutes * 60)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let enabled = defaults.object(forKey: "historyReset.enabled") as? NSNumber
        let minutes = defaults.object(forKey: "historyReset.minutes") as? NSNumber
        let validEnabled = enabled.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        let validMinutes = minutes.flatMap { number -> Int? in
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else { return nil }
            return number.intValue
        }
        return Self(isEnabled: validEnabled ?? true, minutes: validMinutes ?? 1)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: "historyReset.enabled")
        defaults.set(minutes, forKey: "historyReset.minutes")
    }
}
