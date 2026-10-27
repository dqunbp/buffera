import Foundation
import BufferaUpdates

@MainActor enum CheckCount { static var value = 0 }
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    CheckCount.value += 1
    print("PASS", message)
}

func response(_ status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: GitHubReleaseClient.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

func payload(tag: String = "v0.3.0", draft: Bool = false, prerelease: Bool = false,
             asset: Bool = true, assetState: String = "uploaded", assetURL: String? = nil,
             published: Bool = true) -> Data {
    let json: [String: Any] = [
        "tag_name": tag, "draft": draft, "prerelease": prerelease,
        "published_at": published ? "2026-10-27T10:00:00Z" as Any : NSNull(),
        "html_url": "https://untrusted.example/ignored",
        "assets": asset ? [["name": "Buffera-macOS-arm64.dmg", "size": 1024, "state": assetState,
                             "browser_download_url": assetURL ?? "https://github.com/dqunbp/buffera/releases/download/\(tag)/Buffera-macOS-arm64.dmg"]] : []
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Recorder()
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        private var captured: [URLRequest] = []
        func add(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; captured.append(request) }
        var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.add(request)
        client?.urlProtocol(self, didReceive: response(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor func runChecks() async throws {
    for invalid in ["", "0.3", "1.2.3.4", "01.2.3", "1.-2.3", "1.2.3-beta", "1.2.3+meta", " 1.2.3", "１.2.3", "18446744073709551616.0.0"] {
        check(ReleaseVersion(invalid) == nil, "reject malformed version: \(invalid)")
    }
    check(ReleaseVersion("0.10.0")! > ReleaseVersion("0.9.9")!, "numeric minor comparison")
    check(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!, "numeric major comparison")
    check(ReleaseVersion("1.2.10")! > ReleaseVersion("1.2.9")!, "numeric patch comparison")
    check(ReleaseUpdate(tag: "v1.2.3")?.version == ReleaseUpdate(tag: "1.2.3")?.version, "optional v prefix")
    check(ReleaseUpdate(tag: "v1.2.3/../../bad") == nil, "tag cannot alter destination URL")
    let update = try GitHubReleaseClient.parse(data: payload(), response: response())!
    check(update.version.description == "0.3.0", "decode released DMG")
    check(update.pageURL.absoluteString == "https://github.com/dqunbp/buffera/releases/tag/v0.3.0", "ignore untrusted release page URL")
    for (data, label) in [(payload(draft: true), "draft"), (payload(prerelease: true), "prerelease"),
                          (payload(asset: false), "missing DMG"), (payload(assetState: "new"), "unfinished upload"),
                          (payload(assetURL: "https://untrusted.example/app.dmg"), "foreign asset URL"),
                          (payload(published: false), "unpublished release")] {
        let result = try GitHubReleaseClient.parse(data: data, response: response())
        check(result == nil, "ignore \(label)")
    }
    let missing = try GitHubReleaseClient.parse(data: Data(), response: response(404))
    check(missing == nil, "404 is no compatible release")
    for data in [Data(), Data("[]".utf8), payload(tag: "v0.3.0-beta"), Data(repeating: 32, count: 1_048_577)] {
        do { _ = try GitHubReleaseClient.parse(data: data, response: response()); fatalError("Invalid response accepted") }
        catch let error as UpdateCheckFailure { check(error == .invalidResponse, "invalid payload does not claim up to date") }
    }
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    do {
        _ = try GitHubReleaseClient.parse(data: Data(), response: response(429, headers: ["Retry-After": "7200"]), now: epoch)
        fatalError("Rate limit ignored")
    } catch let error as UpdateCheckFailure {
        check(error == .rateLimited(until: epoch.addingTimeInterval(7200)), "honor Retry-After")
    }
    do {
        _ = try GitHubReleaseClient.parse(data: Data(), response: response(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800010000"]), now: epoch)
        fatalError("Rate limit ignored")
    } catch let error as UpdateCheckFailure {
        check(error == .rateLimited(until: epoch.addingTimeInterval(10000)), "honor GitHub reset timestamp")
    }
    do { _ = try GitHubReleaseClient.parse(data: Data(), response: response(503)); fatalError("Server error accepted") }
    catch let error as UpdateCheckFailure { check(error == .unavailable, "server error is not current version") }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let fetched = try await GitHubReleaseClient(session: session).latest()
    check(fetched == update, "real URLSession request decodes fixture response")
    let request = FixtureProtocol.requests.values.last!
    check(request.url == GitHubReleaseClient.endpoint && request.httpMethod == "GET" && request.httpBody == nil,
          "request contains only public release endpoint, no user content")
    check(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil,
          "request has no account credentials or cookies")
    check(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json" && request.timeoutInterval == 20,
          "request uses GitHub API headers and bounded timeout")

    let suite = "Buffera.UpdateChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = epoch
    var calls = 0
    var next: ReleaseUpdate? = update
    var failure: UpdateCheckFailure?
    let fetch: () async throws -> ReleaseUpdate? = {
        calls += 1
        if let failure { throw failure }
        return next
    }
    let checker = UpdateChecker(installedVersion: "0.2.0", supportsRelease: true, defaults: defaults, now: { now }, fetch: fetch)
    check(checker.automaticEnabled && checker.indicatorRelease == nil, "default: enabled, no speculative indicator")
    let first = await checker.check()
    check(first == .available(update) && checker.indicatorRelease == update && calls == 1, "discover newer release")
    _ = await checker.check()
    check(calls == 1, "scheduled checks throttled for 24 hours")
    let restored = UpdateChecker(installedVersion: "0.2.0", supportsRelease: true, defaults: defaults, now: { now }, fetch: fetch)
    _ = await restored.check()
    check(restored.indicatorRelease == update && calls == 1, "cache and interval survive restart")
    restored.skip(update)
    check(restored.indicatorRelease == nil, "skip hides only this release")
    let manual = await restored.check(manual: true)
    check(manual == .available(update) && restored.indicatorRelease == nil && calls == 2, "manual check bypasses daily interval and still offers skipped release")
    next = ReleaseUpdate(tag: "v0.4.0")!
    now = now.addingTimeInterval(UpdateChecker.interval)
    _ = await restored.check()
    check(restored.indicatorRelease == next && calls == 3, "next version appears after a skipped version")
    failure = .unavailable
    let offline = await restored.check(manual: true)
    check(offline == .failed(.unavailable) && restored.indicatorRelease == next, "offline failure retains known update")
    restored.automaticEnabled = false
    now = now.addingTimeInterval(UpdateChecker.interval)
    let disabled = await restored.check()
    check(disabled == nil && calls == 4, "disabled automatic checks perform no request")
    failure = nil
    next = ReleaseUpdate(tag: "v0.2.0")!
    let equal = await restored.check(manual: true)
    check(equal == .upToDate && restored.indicatorRelease == nil, "manual check works when disabled and equal version clears cache")
    next = ReleaseUpdate(tag: "v0.1.0")!
    let older = await restored.check(manual: true)
    check(older == .upToDate && restored.indicatorRelease == nil, "never suggest downgrade")
    next = nil
    let absent = await restored.check(manual: true)
    check(absent == .noCompatibleRelease, "missing artifact does not claim version is current")
    failure = .rateLimited(until: now.addingTimeInterval(7200))
    _ = await restored.check(manual: true)
    let countBeforeLimit = calls
    let limited = await restored.check(manual: true)
    check(limited == .failed(failure!) && calls == countBeforeLimit, "manual retry respects persisted rate limit")
    let intel = UpdateChecker(installedVersion: "0.2.0", supportsRelease: false, defaults: defaults, fetch: fetch)
    let unsupported = await intel.check(manual: true)
    check(unsupported == .noCompatibleRelease && intel.indicatorRelease == nil && calls == countBeforeLimit, "unsupported architecture never offered arm64 package")

    defaults.removePersistentDomain(forName: suite)
    var pending: CheckedContinuation<ReleaseUpdate?, Error>?
    let delayed = UpdateChecker(installedVersion: "0.2.0", supportsRelease: true, defaults: defaults, fetch: {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    })
    let background = Task { await delayed.check() }
    while pending == nil { await Task.yield() }
    let beforeJoin = calls
    let joined = Task { await delayed.check(manual: true) }
    for _ in 0..<10 { await Task.yield() }
    pending?.resume(returning: update); pending = nil
    let backgroundResult = await background.value
    let joinedResult = await joined.value
    check(backgroundResult == .available(update) && joinedResult == backgroundResult && calls == beforeJoin,
          "manual and background callers share one in-flight request")
    let cancelled = Task { await delayed.check(manual: true) }
    while pending == nil { await Task.yield() }
    delayed.stop()
    pending?.resume(returning: ReleaseUpdate(tag: "v9.0.0")); pending = nil
    let cancelledResult = await cancelled.value
    check(cancelledResult == nil && !delayed.isChecking && delayed.availableRelease == update, "stop ignores late results")

    if CommandLine.arguments.contains("--live") {
        let live = try await GitHubReleaseClient().latest()
        check(live != nil, "live public GitHub Releases response has compatible artifact")
        print("LIVE latest stable release:", live!.tag)
    }
    print("PASS \(CheckCount.value) update checks")
}

try await runChecks()
