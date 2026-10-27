import Foundation

public enum UpdateCheckOutcome: Equatable, Sendable {
    case available(ReleaseUpdate)
    case upToDate
    case noCompatibleRelease
    case failed(UpdateCheckFailure)
}

/// Main-thread state, injected clock/transport, and a single shared request.
@MainActor public final class UpdateChecker {
    public static let interval: TimeInterval = 24 * 60 * 60
    private enum Key {
        static let automatic = "updates.automatic"
        static let lastAttempt = "updates.lastAttempt"
        static let latestTag = "updates.latestTag"
        static let skipped = "updates.skippedVersion"
        static let retryAfter = "updates.retryAfter"
    }
    private let defaults: UserDefaults
    private let installed: ReleaseVersion
    private let supportsRelease: Bool
    private let now: () -> Date
    private let fetch: () async throws -> ReleaseUpdate?
    private var inFlight: Task<Result<ReleaseUpdate?, UpdateCheckFailure>, Never>?
    private var generation = 0
    private var latest: ReleaseUpdate?
    public var onChange: (() -> Void)?
    public var isChecking: Bool { inFlight != nil }
    public var automaticEnabled: Bool {
        get { defaults.object(forKey: Key.automatic) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.automatic); onChange?() }
    }
    public var availableRelease: ReleaseUpdate? {
        guard supportsRelease, let latest, latest.version > installed else { return nil }
        return latest
    }
    public var indicatorRelease: ReleaseUpdate? {
        guard let release = availableRelease,
              defaults.string(forKey: Key.skipped) != release.version.description else { return nil }
        return release
    }

    public init(installedVersion: String, supportsRelease: Bool, defaults: UserDefaults = .standard,
                now: @escaping () -> Date = Date.init,
                fetch: @escaping () async throws -> ReleaseUpdate? = { try await GitHubReleaseClient().latest() }) {
        guard let installed = ReleaseVersion(installedVersion) else { preconditionFailure("Invalid app version") }
        self.installed = installed
        self.supportsRelease = supportsRelease
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        latest = defaults.string(forKey: Key.latestTag).flatMap { ReleaseUpdate(tag: $0) }
    }

    public func skip(_ release: ReleaseUpdate) {
        defaults.set(release.version.description, forKey: Key.skipped)
        onChange?()
    }

    /// nil means a scheduled check was not due; manual checks bypass the daily interval.
    public func check(manual: Bool = false) async -> UpdateCheckOutcome? {
        guard supportsRelease else { return manual ? .noCompatibleRelease : nil }
        if let inFlight { return manual ? outcome(await inFlight.value) : nil }
        let date = now()
        if let retry = defaults.object(forKey: Key.retryAfter) as? Date, retry > date {
            return manual ? .failed(.rateLimited(until: retry)) : nil
        }
        if !manual {
            guard automaticEnabled else { return nil }
            if let previous = defaults.object(forKey: Key.lastAttempt) as? Date,
               date >= previous, date.timeIntervalSince(previous) < Self.interval { return nil }
        }
        defaults.set(date, forKey: Key.lastAttempt)
        generation += 1
        let token = generation
        let task = Task { [fetch] () -> Result<ReleaseUpdate?, UpdateCheckFailure> in
            do {
                let release = try await fetch()
                try Task.checkCancellation()
                return .success(release)
            } catch is CancellationError { return .failure(.cancelled) }
            catch let error as UpdateCheckFailure { return .failure(error) }
            catch { return .failure(Task.isCancelled ? .cancelled : .unavailable) }
        }
        inFlight = task
        onChange?()
        let result = await task.value
        guard token == generation else { return nil }
        inFlight = nil
        switch result {
        case .success(let release):
            latest = release
            defaults.set(release?.tag, forKey: Key.latestTag)
            defaults.removeObject(forKey: Key.retryAfter)
        case .failure(.rateLimited(let retry)):
            defaults.set(retry, forKey: Key.retryAfter)
        case .failure: break // Keep a previously discovered update across offline checks.
        }
        onChange?()
        return outcome(result)
    }

    public func stop() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
    }

    private func outcome(_ result: Result<ReleaseUpdate?, UpdateCheckFailure>) -> UpdateCheckOutcome {
        switch result {
        case .success(let release?): return release.version > installed ? .available(release) : .upToDate
        case .success(nil): return .noCompatibleRelease
        case .failure(let error): return .failed(error)
        }
    }
}
