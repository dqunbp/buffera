import AppKit
import BufferaCore
import BufferaUpdates
import Sparkle

@MainActor private final class FixturePinnedUpdateUserDriver: ReleasePinnedUpdateUserDriver {
    var presented: [SUAppcastItem] = []

    override func presentUpdate(_ item: SUAppcastItem, state: SPUUserUpdateState,
                                reply: @escaping (SPUUserUpdateChoice) -> Void) {
        presented.append(item)
        reply(.dismiss)
    }
}

/// Exercise the actual Sparkle user-driver callback used for resumed updates,
/// without displaying windows, downloading archives or starting an installer.
@MainActor func checkUpdateInstallerReleasePin() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw HistoryError.database(message) }
    }
    func item(version: String, url: URL) throws -> SUAppcastItem {
        // Sparkle's public dictionary initializer is sufficient for these two
        // fields; tests do not use its unsupported OS/application comparisons.
        guard let item = SUAppcastItem(dictionary: ["enclosure": [
            "url": url.absoluteString, "sparkle:version": "999",
            "sparkle:shortVersionString": version, "length": "1", "type": "application/octet-stream"
        ]]) else { throw HistoryError.database("Invalid fixture appcast item") }
        return item
    }
    func state(_ stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        // Use Sparkle's NSSecureCoding contract; its state initializer is private.
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        encoder.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        defer { decoder.finishDecoding() }
        guard let state = SPUUserUpdateState(coder: decoder) else {
            throw HistoryError.database("Invalid fixture update state")
        }
        return state
    }
    let release = ReleaseUpdate(tag: "v99.0.0")!
    let previous = ReleaseUpdate(tag: "v98.0.0")!
    let expected = try item(version: release.version.description, url: release.downloadURL)
    let stale = try item(version: previous.version.description, url: previous.downloadURL)
    let wrongURL = try item(version: release.version.description, url: previous.downloadURL)
    let wrongVersion = try item(version: previous.version.description, url: release.downloadURL)
    var selected: ReleaseUpdate? = release
    let driver = FixturePinnedUpdateUserDriver(hostBundle: .main, delegate: nil)
    driver.allowsUpdate = { selected?.matchesAppcastItem($0) == true }
    var rejections = 0
    driver.onRejectedUpdate = { rejections += 1 }
    for stage in [SPUUserUpdateStage.notDownloaded, .downloaded, .installing] {
        let updateState = try state(stage)
        try check(updateState.stage == stage && updateState.userInitiated,
                  "Fixture must preserve the real Sparkle resumed stage")
        for rejectedItem in [stale, wrongURL, wrongVersion] {
            var choices: [SPUUserUpdateChoice] = []
            let before = rejections
            driver.showUpdateFound(with: rejectedItem, state: updateState, reply: { choices.append($0) })
            try check(choices == [.skip] && driver.presented.isEmpty && rejections == before + 1,
                      "A mismatched fresh/resumed update must cancel exactly once before offering installation")
        }
        selected = nil
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: expected, state: updateState, reply: { choices.append($0) })
        try check(choices == [.skip] && driver.presented.isEmpty,
                  "A late resumed callback without a selected release must cancel")
        selected = release
        choices = []
        let before = rejections
        driver.showUpdateFound(with: expected, state: updateState, reply: { choices.append($0) })
        try check(choices == [.dismiss] && driver.presented == [expected] && rejections == before,
                  "A matching update must reach the standard presentation path and preserve its response")
        driver.presented = []
    }
}
