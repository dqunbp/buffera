import Foundation
import BufferaLocalization

enum AppRelaunch {
    /// Wait for the old process to exit before opening the bundle: the app rejects
    /// concurrent instances to keep one owner of the history observer and hotkeys.
    static func schedule(bundle: Bundle = .main) throws {
        guard bundle.bundleURL.pathExtension == "app",
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RelaunchError.unbundled
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Paths are positional arguments, never interpolated into shell code.
        helper.arguments = ["-c", """
            while kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
            exec /usr/bin/open -n "$2" --args --show-settings
            """, "buffera-relaunch", String(ProcessInfo.processInfo.processIdentifier), bundle.bundleURL.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    private enum RelaunchError: LocalizedError {
        case unbundled
        var errorDescription: String? {
            L10n.text("Не удалось подготовить перезапуск. Закройте Buffera и откройте приложение снова.")
        }
    }
}
