import AppKit
import BufferaCore
import BufferaLocalization
import BufferaUpdates
import Sparkle

extension ReleaseUpdate {
    func matchesAppcastItem(_ item: SUAppcastItem) -> Bool {
        item.displayVersionString == version.description && item.fileURL == downloadURL
    }
}

/// Sparkle skips shouldProceedWithUpdate for resumed downloads/installations.
/// Its user-driver entry point sees every item before offering an install action.
@MainActor class ReleasePinnedUpdateUserDriver: SPUStandardUserDriver {
    var allowsUpdate: ((SUAppcastItem) -> Bool)?
    var onRejectedUpdate: (() -> Void)?

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard allowsUpdate?(appcastItem) == true else {
            onRejectedUpdate?()
            // Dismiss keeps a staged install alive, including installation on quit.
            // Skip clears a downloaded archive or cancels the pending installer.
            reply(.skip)
            return
        }
        presentUpdate(appcastItem, state: state, reply: reply)
    }

    func presentUpdate(_ item: SUAppcastItem, state: SPUUserUpdateState,
                       reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.showUpdateFound(with: item, state: state, reply: reply)
    }
}

/// Sparkle owns download, verification, replacement and relaunch. GitHub remains
/// the only background checker; this adapter starts solely after an explicit click.
@MainActor protocol UpdateInstalling: AnyObject {
    var isBusy: Bool { get }
    var onChange: (() -> Void)? { get set }
    var onSkip: ((ReleaseUpdate) -> Void)? { get set }
    func install(_ release: ReleaseUpdate) throws
}

@MainActor final class UpdateInstaller: NSObject, UpdateInstalling, SPUUpdaterDelegate {
    var onChange: (() -> Void)?
    var onSkip: ((ReleaseUpdate) -> Void)?
    private(set) var isBusy = false
    private var selectedRelease: ReleaseUpdate?
    private var started = false
    private var rejectedResumedUpdate = false
    private lazy var userDriver: ReleasePinnedUpdateUserDriver = {
        let driver = ReleasePinnedUpdateUserDriver(hostBundle: .main, delegate: nil)
        driver.allowsUpdate = { [weak self] item in
            self?.selectedRelease?.matchesAppcastItem(item) == true
        }
        driver.onRejectedUpdate = { [weak self] in self?.rejectedResumedUpdate = true }
        return driver
    }()
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                         userDriver: userDriver, delegate: self)

    func install(_ release: ReleaseUpdate) throws {
        guard !isBusy else { return }
        guard let installed = ReleaseVersion(AppVersion.version), release.version > installed else {
            throw installationError()
        }
        selectedRelease = release
        do {
            if !started {
                try updater.start()
                started = true
            }
            guard updater.canCheckForUpdates else { throw installationError() }
            isBusy = true
            onChange?()
            updater.checkForUpdates()
        } catch {
            selectedRelease = nil
            isBusy = false
            onChange?()
            throw error
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        selectedRelease?.appcastURL.absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates, isBusy, selectedRelease != nil else { throw installationError() }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        // A tag-specific feed must not redirect an explicit install to another release.
        guard let release = selectedRelease, updateCheck == .updates,
              release.matchesAppcastItem(item) else { throw installationError() }
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip, let release = selectedRelease, release.matchesAppcastItem(item) {
            onSkip?(release)
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard updateCheck == .updates else { return }
        let rejected = rejectedResumedUpdate
        rejectedResumedUpdate = false
        selectedRelease = nil
        isBusy = false
        onChange?()
        if rejected { userDriver.showUpdaterError(installationError(), acknowledgement: {}) }
    }

    private func installationError() -> NSError {
        NSError(domain: "Buffera.UpdateInstaller", code: 1, userInfo: [
            NSLocalizedDescriptionKey: L10n.text("Не удалось начать обновление. Повторите попытку или откройте релиз для ручной установки.")
        ])
    }
}
