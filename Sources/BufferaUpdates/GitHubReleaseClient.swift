import Foundation

public enum UpdateCheckFailure: Error, Equatable, Sendable {
    case unavailable
    case invalidResponse
    case rateLimited(until: Date)
    case cancelled
}

/// Only public release metadata is requested. No history, credentials or cookies.
public struct GitHubReleaseClient: Sendable {
    public static let endpoint = URL(string: "https://api.github.com/repos/dqunbp/buffera/releases/latest")!
    private let session: URLSession

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func latest() async throws -> ReleaseUpdate? {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Buffera-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url == Self.endpoint else {
            throw UpdateCheckFailure.invalidResponse
        }
        return try Self.parse(data: data, response: http)
    }

    public static func parse(data: Data, response: HTTPURLResponse, now: Date = Date()) throws -> ReleaseUpdate? {
        if response.statusCode == 404 { return nil }
        if response.statusCode == 403 || response.statusCode == 429 {
            var retry = now.addingTimeInterval(3600)
            if let value = response.value(forHTTPHeaderField: "Retry-After"),
               let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
                retry = max(retry, now.addingTimeInterval(seconds))
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let epoch = TimeInterval(value), epoch.isFinite {
                retry = max(retry, Date(timeIntervalSince1970: epoch))
            }
            throw UpdateCheckFailure.rateLimited(until: retry)
        }
        guard response.statusCode == 200 else { throw UpdateCheckFailure.unavailable }
        guard data.count <= 1_048_576,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let update = ReleaseUpdate(tag: release.tag_name) else { throw UpdateCheckFailure.invalidResponse }
        guard !release.draft, !release.prerelease, release.published_at != nil,
              release.assets.contains(where: {
                  $0.name == "Buffera-macOS-arm64.dmg" && $0.state == "uploaded" && $0.size > 0
                      && $0.browser_download_url == update.downloadURL.absoluteString
              }) else { return nil }
        return update
    }
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let published_at: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int64
        let browser_download_url: String
    }
}
