import AppKit
import BufferaCore
import BufferaUpdates

/// Schedules checks and connects their state to settings and the menu-bar badge.
@MainActor final class AppUpdateController {
    let settingsView = UpdateSettingsView()
    var onIndicatorChange: ((ReleaseUpdate?) -> Void)?
    private let checker: UpdateChecker
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var running = false
    private var lastOutcome: UpdateCheckOutcome?

    init(checker: UpdateChecker? = nil) {
        #if arch(arm64)
        let supported = true
        #else
        let supported = false
        #endif
        self.checker = checker ?? UpdateChecker(installedVersion: AppVersion.version, supportsRelease: supported)
        self.checker.onChange = { [weak self] in self?.refreshInterface() }
        settingsView.onCheck = { [weak self] in self?.check(manual: true) }
        settingsView.onAutomaticChange = { [weak self] enabled in
            guard let self else { return }
            self.checker.automaticEnabled = enabled
            if enabled { self.check() }
        }
        settingsView.onOpenRelease = { [weak self] in
            guard let self, let release = self.checker.availableRelease else { return }
            if !NSWorkspace.shared.open(release.pageURL) { self.settingsView.showBrowserError() }
        }
        settingsView.onSkip = { [weak self] in
            guard let self, let release = self.checker.availableRelease else { return }
            self.checker.skip(release)
        }
        refreshInterface()
    }

    func start() {
        guard !running else { return }
        running = true
        refreshInterface()
        check()
        // Only request metadata when the persisted 24-hour interval has elapsed.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        timer?.tolerance = 60
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.check() } }
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        checker.stop()
    }

    private func check(manual: Bool = false) {
        guard running else { return }
        Task { [weak self] in
            guard let self, let result = await checker.check(manual: manual), running else { return }
            lastOutcome = result
            refreshInterface()
        }
    }

    private func refreshInterface() {
        let release = checker.availableRelease
        settingsView.render(automatic: checker.automaticEnabled, checking: checker.isChecking,
                            release: release, skipped: release != nil && checker.indicatorRelease == nil,
                            outcome: lastOutcome)
        onIndicatorChange?(checker.indicatorRelease)
    }
}
