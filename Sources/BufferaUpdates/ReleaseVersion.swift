import Foundation

/// Stable X.Y.Z only, matching scripts/version.sh. Compare components numerically.
public struct ReleaseVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    private let parts: [UInt64]
    public let description: String

    public init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, value.utf8.count <= 64 else { return nil }
        var parts: [UInt64] = []
        for component in components {
            guard !component.isEmpty, component.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  component.count == 1 || component.first != "0", let number = UInt64(component) else { return nil }
            parts.append(number)
        }
        self.parts = parts
        description = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public struct ReleaseUpdate: Equatable, Sendable {
    public let tag: String
    public let version: ReleaseVersion
    public var pageURL: URL { URL(string: "https://github.com/dqunbp/buffera/releases/tag/\(tag)")! }
    public var downloadURL: URL {
        URL(string: "https://github.com/dqunbp/buffera/releases/download/\(tag)/Buffera-macOS-arm64.dmg")!
    }

    public init?(tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let version = ReleaseVersion(value) else { return nil }
        self.tag = tag
        self.version = version
    }
}
