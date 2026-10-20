import Foundation
import CoreFoundation

/// The same limits used by capture and the settings window. Favorites are exempt.
struct HistoryLimits: Equatable {
    static let countChoices = [10_000, 50_000, 100_000]
    static let bytesPerGigabyte = 1_000_000_000
    static let byteRange = bytesPerGigabyte...(20 * bytesPerGigabyte)

    var maxCount: Int { didSet { maxCount = Self.clampedCount(maxCount) } }
    var maxBytes: Int { didSet { maxBytes = Self.clampedBytes(maxBytes) } }

    init(maxCount: Int = 50_000, maxBytes: Int = 5_000_000_000) {
        self.maxCount = Self.clampedCount(maxCount)
        self.maxBytes = Self.clampedBytes(maxBytes)
    }

    static func load(from defaults: UserDefaults = .standard) -> HistoryLimits {
        HistoryLimits(maxCount: integer(from: defaults, key: "maxCount") ?? 50_000,
                      maxBytes: integer(from: defaults, key: "maxBytes") ?? 5_000_000_000)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(maxCount, forKey: "maxCount")
        defaults.set(maxBytes, forKey: "maxBytes")
    }

    private static func clampedCount(_ value: Int) -> Int { min(100_000, max(10_000, value)) }
    private static func clampedBytes(_ value: Int) -> Int { min(byteRange.upperBound, max(byteRange.lowerBound, value)) }

    private static func integer(from defaults: UserDefaults, key: String) -> Int? {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
}
