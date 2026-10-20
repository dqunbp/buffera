import Foundation

// swiftc -module-cache-path .build/ModuleCache Sources/Buffera/HistoryLimits.swift Sources/BufferaCore/MCPAccess.swift Tests/SettingsChecks/main.swift -o .build/settings-checks/checks
// .build/settings-checks/checks
// Isolated defaults and temporary files only: no UI or real application preferences.
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
for (count, bytes) in zip(HistoryLimits.countChoices, [1, 5, 20].map { $0 * HistoryLimits.bytesPerGigabyte }) {
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

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BufferaMCPSettings-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: temporary) }
let access = MCPAccess(directory: temporary.appendingPathComponent("data"))
let permissionURL = access.directory.appendingPathComponent("mcp-access.json")
check(!access.isEnabled(), "MCP access defaults to disabled without a permission file")
check(!FileManager.default.fileExists(atPath: access.directory.path), "reading disabled access does not create a directory")
check(access.databaseURL == access.directory.appendingPathComponent("history.sqlite"), "MCP and app share the configured database location")
try access.setEnabled(true)
check(access.isEnabled(), "explicit opt-in enables access")
let helperAccess = MCPAccess(directory: access.directory)
check(helperAccess.isEnabled(), "another access instance observes saved opt-in")
let permissions = try FileManager.default.attributesOfItem(atPath: permissionURL.path)[.posixPermissions] as? NSNumber
check(permissions?.intValue == 0o600, "published permission file is readable and writable only by its owner")
try access.setEnabled(false)
check(!helperAccess.isEnabled(), "already constructed helper observes revocation on its next read")
try access.setEnabled(true)
check(helperAccess.isEnabled(), "already constructed helper observes a subsequent explicit opt-in")
for invalid in ["", "{", "{}", "{\"version\":2,\"enabled\":true}", "{\"version\":1,\"enabled\":1}",
                "{\"version\":1,\"enabled\":\"true\"}", "{\"enabled\":true}", "null"] {
    try Data(invalid.utf8).write(to: permissionURL)
    check(!helperAccess.isEnabled(), "missing, malformed or unknown permission state fails closed")
}
try Data(repeating: 32, count: 4097).write(to: permissionURL)
check(!helperAccess.isEnabled(), "oversized permission files fail closed")
try access.setEnabled(true)
try FileManager.default.removeItem(at: permissionURL)
check(!helperAccess.isEnabled(), "removing the permission file revokes access immediately")
try FileManager.default.createDirectory(at: permissionURL, withIntermediateDirectories: false)
check(!helperAccess.isEnabled(), "a directory at the permission path cannot grant access")
do {
    try access.setEnabled(true)
    fatalError("publishing over a directory should fail")
} catch {
    check(!helperAccess.isEnabled(), "failed permission publication leaves access disabled")
}
let remaining = try FileManager.default.contentsOfDirectory(atPath: access.directory.path)
check(remaining == ["mcp-access.json"], "failed atomic publication cleans its temporary file")
try FileManager.default.removeItem(at: permissionURL)
for value in [true, false, true, false] {
    try access.setEnabled(value)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: permissionURL)) as? [String: Any]
    check(saved?["enabled"] as? Bool == value, "each published permission is a complete JSON document")
}
let executable = URL(fileURLWithPath: "/tmp/Agent \"demo\"/Приложение.app/Contents/MacOS/BufferaMCP")
let configuration = try MCPAccess.configuration(executableURL: executable)
let object = try JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any]
let servers = object?["mcpServers"] as? [String: [String: Any]]
check(servers?["buffera"]?["command"] as? String == executable.path, "config safely preserves an absolute executable path with spaces and quotes")
check((servers?["buffera"]?["args"] as? [String]) == [], "stdio config has no implicit arguments or shell command")
check(!access.isEnabled(), "generating connection configuration never enables access")

// Exercise the generated command through real shell parsers, without invoking either real CLI.
func commandArguments(_ command: String, shell: String) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
    let script = """
        claude() { printf '%s\\0' claude "$@"; }
        codex() { printf '%s\\0' codex "$@"; }
        \(command)
        """
    process.arguments = shell == "/bin/bash" ? ["--noprofile", "--norc", "-c", script] : ["-f", "-c", script]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    let errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    check(process.terminationStatus == 0 && errorBytes.isEmpty, "mock CLI command completes cleanly in \(shell)")
    return bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
}

let commandPaths = [
    "/Applications/Buffera.app/Contents/MacOS/BufferaMCP",
    "/tmp/Приложения на Mac/Owner's Buffera.app/Contents/MacOS/BufferaMCP",
    "/tmp/\"quoted\" $BUFFERA_MCP_TEST `printf unexpected` $(printf unexpected);printf unexpected/BufferaMCP",
    "/tmp/back\\slash and\nnew line/BufferaMCP"
]
let clients: [(MCPClient, [String])] = [
    (.claudeCode, ["claude", "mcp", "add", "--transport", "stdio", "--scope", "user", "buffera", "--"]),
    (.codex, ["codex", "mcp", "add", "buffera", "--"])
]
for (client, expectedPrefix) in clients {
    for path in commandPaths {
        let url = URL(fileURLWithPath: path)
        let command = MCPAccess.addCommand(for: client, executableURL: url)
        check(command.hasPrefix(expectedPrefix.joined(separator: " ") + " '") && command.hasSuffix("'"),
              "CLI command keeps the verified prefix and always quotes its executable path")
        for shell in ["/bin/bash", "/bin/zsh"] {
            let arguments = try commandArguments(command, shell: shell)
            check(arguments == expectedPrefix + [url.path], "shell passes the complete executable path literally as one argument")
        }
    }
}
check(!access.isEnabled(), "generating CLI commands never enables MCP access")
print("PASS \(checks) settings persistence checks")
