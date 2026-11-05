import Foundation
import BufferaCore
import BufferaLocalization

/// Explicit allowlist: no history, environment variables, paths, logs or machine identifiers.
enum IssueReport {
    static func url() -> URL {
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let body = """
        ### \(L10n.text("Что произошло?"))

        ### \(L10n.text("Что ожидалось?"))

        ### \(L10n.text("Как повторить?"))

        ---
        Buffera: \(AppVersion.version) (\(AppVersion.build))
        macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Architecture: \(architecture)
        """
        var components = URLComponents(string: "https://github.com/dqunbp/buffera/issues/new")!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url!
    }
}
