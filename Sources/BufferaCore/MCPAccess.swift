import Foundation
import Darwin

public enum MCPClient {
    case claudeCode
    case codex
}

/// Explicit, revocable permission shared by the app and its stdio helper.
/// Read from disk for every operation: an already running helper must observe revocation.
public struct MCPAccess {
    public static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                 in: .userDomainMask)[0]
        .appendingPathComponent("Buffera", isDirectory: true)

    public let directory: URL
    public var databaseURL: URL { directory.appendingPathComponent("history.sqlite") }
    private var accessURL: URL { directory.appendingPathComponent("mcp-access.json") }

    public init(directory: URL = Self.defaultDirectory) { self.directory = directory }

    public func isEnabled() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: accessURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 4096,
              let data = try? Data(contentsOf: accessURL),
              let permission = try? JSONDecoder().decode(Permission.self, from: data),
              permission.version == 1 else { return false }
        return permission.enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Permission(version: 1, enabled: enabled))
        let temporary = directory.appendingPathComponent(".mcp-access-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        // Both paths share a directory. Readers see either complete permission file.
        guard rename(temporary.path, accessURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    public static func configuration(executableURL: URL) throws -> String {
        let object: [String: Any] = ["mcpServers": ["buffera": [
            "command": executableURL.path, "args": [String]()
        ]]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns a command for the user to run; generating it never invokes a client or grants access.
    public static func addCommand(for client: MCPClient, executableURL: URL) -> String {
        let prefix: String
        switch client {
        case .claudeCode: prefix = "claude mcp add --transport stdio --scope user buffera --"
        case .codex: prefix = "codex mcp add buffera --"
        }
        // A quote ends the quoted segment, is escaped outside it, then starts a new segment.
        let path = "'" + executableURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return prefix + " " + path
    }

    private struct Permission: Codable {
        let version: Int
        let enabled: Bool
    }
}
