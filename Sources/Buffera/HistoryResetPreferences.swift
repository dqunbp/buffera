import Foundation
import CoreFoundation

struct HistoryResetPreferences: Equatable {
    enum Timing: String {
        case immediately
        case afterDelay
    }

    static let minuteRange = 1...1440
    let isEnabled: Bool
    let minutes: Int
    let timing: Timing
    var resetsImmediately: Bool { isEnabled && timing == .immediately }

    init(isEnabled: Bool = true, minutes: Int = 1, timing: Timing = .afterDelay) {
        self.isEnabled = isEnabled
        self.minutes = min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, minutes))
        self.timing = timing
    }

    func shouldReset(closedAt: Date?, now: Date) -> Bool {
        guard isEnabled, let closedAt else { return false }
        return resetsImmediately || now.timeIntervalSince(closedAt) >= TimeInterval(minutes * 60)
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
        let timing = defaults.string(forKey: "historyReset.timing").flatMap(Timing.init(rawValue:)) ?? .afterDelay
        return Self(isEnabled: validEnabled ?? true, minutes: validMinutes ?? 1, timing: timing)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: "historyReset.enabled")
        defaults.set(minutes, forKey: "historyReset.minutes")
        defaults.set(timing.rawValue, forKey: "historyReset.timing")
    }
}
