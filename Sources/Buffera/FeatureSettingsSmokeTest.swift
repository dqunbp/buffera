import AppKit
import BufferaCore
import BufferaModels
import CryptoKit

/// Exercises settings against temporary files without opening a window or starting a download.
func runFeatureSettingsSmokeTest() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    try checkBackgroundPreparationPolicy()
    let fresh = try FeatureSettingsFixture(state: .notDownloaded)
    defer { fresh.cleanup() }
    let search = try fresh.control("models.embedding.enabled", as: NSButton.self)
    let assistant = try fresh.control("models.assistant.enabled", as: NSButton.self)
    try featureCheck(!search.isEnabled && !assistant.isEnabled,
                     "Fresh feature switches bypass the explicit download action")
    try featureCheck(search.state == .off && assistant.state == .off,
                     "Fresh features unexpectedly start enabled")
    for role in ModelRole.allCases {
        let prefix = "models.\(role.rawValue)"
        let status = try fresh.control("\(prefix).status", as: NSTextField.self)
        let download = try fresh.control("\(prefix).download", as: NSButton.self)
        let name = try fresh.control("\(prefix).name", as: NSTextField.self)
        let energyNote = try fresh.control("\(prefix).energyNote", as: NSTextField.self)
        let snapshot = fresh.manager.snapshots.first { $0.descriptor.role == role }!
        try featureCheck(!status.isHiddenOrHasHiddenAncestor && !status.stringValue.isEmpty,
                         "The missing model has no visible preparation status")
        try featureCheck(!name.isHiddenOrHasHiddenAncestor &&
                         name.stringValue.contains(snapshot.descriptor.title) &&
                         name.stringValue.contains("\(snapshot.totalBytes)"),
                         "Model identity and download size are hidden before activation")
        try featureCheck(!download.isHiddenOrHasHiddenAncestor && download.title == "Скачать модель и включить",
                         "The explicit download-and-enable action is missing")
        try featureCheck(!energyNote.isHiddenOrHasHiddenAncestor && !energyNote.stringValue.isEmpty,
                         "A local feature omits its energy-use explanation")
        #if arch(arm64)
        try featureCheck(download.isEnabled, "The explicit download action is unavailable on a supported Mac")
        #endif
    }
    let powerPreference = try fresh.control("models.embedding.onlyOnExternalPower", as: NSButton.self)
    try featureCheck(powerPreference.state == .on, "Background preparation is not restricted to external power by default")
    var powerChanges: [Bool] = []
    fresh.view.onOnlyPrepareOnExternalPowerChanged = { powerChanges.append($0) }
    #if arch(arm64)
    powerPreference.performClick(nil)
    try featureCheck(powerChanges == [false], "Power preference did not propagate its new value")
    #endif
    fresh.view.updateBackgroundPreparation(onlyOnExternalPower: true)
    try featureCheck(powerPreference.state == .on, "Saved power preference is not reflected in settings")
    try fresh.checkLayout()

    let installed = try FeatureSettingsFixture(state: .downloaded)
    defer { installed.cleanup() }
    try installed.waitUntil { $0.allSatisfy { $0.state == .downloaded } }
    let toggle = try installed.control("models.embedding.enabled", as: NSButton.self)
    let remove = try installed.control("models.embedding.remove", as: NSButton.self)
    let details = try installed.control("models.embedding.details", as: NSButton.self)
    let name = try installed.control("models.embedding.name", as: NSTextField.self)
    let check = try installed.control("models.embedding.check", as: NSButton.self)
    let license = try installed.control("models.embedding.license", as: NSButton.self)
    let card = try installed.control("models.embedding", as: NSBox.self)
    let collapsedHeight = card.frame.height
    var disabled: [ModelRole] = []
    var checks: [ModelRole] = []
    installed.view.onWillDisableOrRemove = { disabled.append($0) }
    installed.view.onCheck = { checks.append($0) }

    try featureCheck(!name.isHiddenOrHasHiddenAncestor &&
                     check.isHiddenOrHasHiddenAncestor && license.isHiddenOrHasHiddenAncestor,
                     "Collapsed details hide the model identity or expose technical actions")
    details.performClick(nil)
    installed.layout()
    try featureCheck(!check.isHiddenOrHasHiddenAncestor && !license.isHiddenOrHasHiddenAncestor,
                     "Details do not reveal diagnostics and the license")
    try featureCheck(card.frame.height > collapsedHeight,
                     "Expanded details overlap the collapsed feature card")
    try installed.checkLayout()
    details.performClick(nil)
    installed.layout()
    try featureCheck(abs(card.frame.height - collapsedHeight) < 1,
                     "Collapsing details leaves an empty expanded card")
    try featureCheck(!name.isHiddenOrHasHiddenAncestor,
                     "Collapsing technical details also hides the model identity")

    #if arch(arm64)
    try featureCheck(check.isEnabled, "An installed but disabled model cannot be checked explicitly")
    let descriptor = installed.manager.snapshots.first { $0.descriptor.role == .embedding }!.descriptor
    let existingURL = installed.root.appendingPathComponent("embedding")
        .appendingPathComponent(descriptor.revision).appendingPathComponent(descriptor.filename)
    toggle.performClick(nil)
    try installed.waitUntil { $0.first(where: { $0.descriptor.role == .embedding })?.isReadyForUse == true }
    try featureCheck(installed.manager.modelURL(for: .embedding) == existingURL,
                     "Activating an installed feature discarded its files")
    details.performClick(nil)
    check.performClick(nil)
    try featureCheck(checks == [.embedding], "Diagnostics action lost its feature role")
    installed.view.updateEmbeddingIndex(status: "Подготовлено 3 из 7 записей", progress: 3.0 / 7,
                                       canRetry: true, canContinueNow: true)
    let index = try installed.control("models.embedding.indexStatus", as: NSTextField.self)
    let indexProgress = try installed.control("models.embedding.indexProgress", as: NSProgressIndicator.self)
    let retry = try installed.control("models.embedding.retryIndex", as: NSButton.self)
    let continuePreparation = try installed.control("models.embedding.continuePreparation", as: NSButton.self)
    var continued = 0
    installed.view.onContinueEmbeddingPreparation = { continued += 1 }
    try featureCheck(!continuePreparation.isHidden, "Battery pause does not offer its temporary continuation action")
    continuePreparation.performClick(nil)
    try featureCheck(continued == 1, "Continue-now action did not reach the preparation policy")
    try featureCheck(!index.isHidden && !indexProgress.isHidden && !retry.isHidden,
                     "An active feature does not show index preparation")
    toggle.performClick(nil)
    try installed.waitUntil { $0.first(where: { $0.descriptor.role == .embedding })?.isEnabled == false }
    try featureCheck(disabled == [.embedding], "Disabling did not stop the feature before changing its preference")
    try featureCheck(index.isHidden && indexProgress.isHidden && retry.isHidden && continuePreparation.isHidden,
                     "Disabled search retains stale indexing controls")
    try featureCheck(installed.manager.modelURL(for: .embedding) == existingURL,
                     "Disabling removed files needed for reactivation")
    remove.performClick(nil)
    try installed.waitUntil { $0.first(where: { $0.descriptor.role == .embedding })?.state == .notDownloaded }
    try featureCheck(disabled == [.embedding, .embedding] && installed.manager.modelURL(for: .embedding) == nil,
                     "Removal did not stop the feature and remove its files")
    #endif

    let paused = try FeatureSettingsFixture(state: .paused, enabled: true)
    defer { paused.cleanup() }
    let pausedToggle = try paused.control("models.embedding.enabled", as: NSButton.self)
    let resume = try paused.control("models.embedding.download", as: NSButton.self)
    try featureCheck(pausedToggle.state == .on && resume.title == "Продолжить",
                     "Paused preparation loses the activation request or resume action")
    #if arch(arm64)
    try featureCheck(pausedToggle.isEnabled, "Requested preparation cannot be disabled while it is paused")
    // The complete partial file makes resume perform only local verification.
    resume.performClick(nil)
    try paused.waitUntil { $0.first(where: { $0.descriptor.role == .embedding })?.isReadyForUse == true }
    try featureCheck(resume.isHidden && pausedToggle.state == .on,
                     "Finishing preparation does not activate the requested feature")
    #endif
    let failed = try FeatureSettingsFixture(state: .failed, enabled: true)
    defer { failed.cleanup() }
    let failureRetry = try failed.control("models.embedding.download", as: NSButton.self)
    let failure = try failed.control("models.embedding.status", as: NSTextField.self)
    try featureCheck(failureRetry.title == "Повторить" && failure.stringValue == "Проверка ошибки загрузки",
                     "Preparation failure hides its error or recovery action")
    try featureCheck([fresh, installed, paused, failed].allSatisfy { !$0.window.isVisible },
                     "Settings checks unexpectedly opened a window")
}

private func featureCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HistoryError.database(message) }
}

private func checkBackgroundPreparationPolicy() throws {
    func environment(_ power: BackgroundPreparationEnvironment.PowerSource, lowPower: Bool = false,
                     thermal: ProcessInfo.ThermalState = .nominal) -> BackgroundPreparationEnvironment {
        BackgroundPreparationEnvironment(powerSource: power, lowPowerMode: lowPower, thermalState: thermal)
    }
    var policy = BackgroundPreparationPolicy(environment: environment(.battery))
    try featureCheck(policy.onlyOnExternalPower && policy.pauseReason == .battery,
                     "Initial battery session allows background preparation by default")
    policy.continueOnBattery()
    try featureCheck(policy.pauseReason == nil, "Explicit continuation does not allow the current battery session")
    policy.updateEnvironment(environment(.battery, lowPower: true))
    try featureCheck(policy.pauseReason == .lowPowerMode, "Battery continuation overrides Low Power Mode")
    policy.updateEnvironment(environment(.battery, thermal: .serious))
    try featureCheck(policy.pauseReason == .thermalPressure, "Battery continuation overrides serious thermal pressure")
    policy.continueOnBattery()
    try featureCheck(policy.pauseReason == .thermalPressure, "Continue-now bypasses thermal protection")
    policy.updateEnvironment(environment(.battery))
    try featureCheck(policy.pauseReason == nil, "Cooling down lost the same battery-session override")
    policy.updateEnvironment(environment(.external))
    policy.updateEnvironment(environment(.battery))
    try featureCheck(policy.pauseReason == .battery, "An AC connection did not reset the battery-session override")
    let relaunched = BackgroundPreparationPolicy(environment: environment(.battery))
    try featureCheck(relaunched.pauseReason == .battery, "A new policy retained a previous session override")
    policy.onlyOnExternalPower = false
    try featureCheck(policy.pauseReason == nil, "Disabling the power preference does not allow battery preparation")
    policy.updateEnvironment(environment(.external, lowPower: true))
    try featureCheck(policy.pauseReason == .lowPowerMode, "Low Power Mode is ignored on external power")
    policy.updateEnvironment(environment(.external, thermal: .critical))
    try featureCheck(policy.pauseReason == .thermalPressure, "Critical thermal pressure is ignored on external power")
    policy.onlyOnExternalPower = true
    policy.updateEnvironment(environment(.unknown))
    try featureCheck(policy.pauseReason == .powerSourceUnknown, "Unknown power source is treated as unlimited power")
    policy.updateEnvironment(environment(.external, thermal: .fair))
    try featureCheck(policy.pauseReason == nil, "Recovering power and thermal state does not resume preparation")
}

private final class FeatureSettingsFixture {
    let root: URL
    let manager: LocalModelManager
    let view: ModelSettingsView
    let window: NSWindow

    init(state: ModelState, enabled: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-feature-ui-\(UUID())")
        let payload = Data("Temporary settings fixture".utf8)
        let revision = String(repeating: "a", count: 40)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let descriptors = ModelRole.allCases.map {
            LocalModelDescriptor(role: $0, title: "Тестовые файлы", summary: "Temporary UI fixture",
                repository: "fixture/fixture", revision: revision, filename: "fixture.gguf",
                byteCount: Int64(payload.count), sha256: hash,
                sourceURL: URL(string: "http://127.0.0.1:1/unused")!,
                licenseURL: URL(string: "https://example.com/license")!)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var receipts: [String: Any] = [:]
        for descriptor in descriptors {
            receipts[descriptor.role.rawValue] = [
                "revision": revision, "sha256": hash, "state": state.rawValue,
                "enabled": enabled, "error": state == .failed ? "Проверка ошибки загрузки" : NSNull()
            ]
            if state == .downloaded || state == .paused {
                let directory = root.appendingPathComponent(descriptor.role.rawValue).appendingPathComponent(revision)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let filename = descriptor.filename + (state == .paused ? ".part" : "")
                try payload.write(to: directory.appendingPathComponent(filename))
            }
        }
        try JSONSerialization.data(withJSONObject: receipts).write(to: root.appendingPathComponent("state.json"))
        manager = try LocalModelManager(rootURL: root, descriptors: descriptors)
        view = ModelSettingsView(manager: manager)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        manager.onChange = { [weak view] in view?.update($0) }
        layout()
    }

    func control<T: NSView>(_ identifier: String, as type: T.Type) throws -> T {
        guard let found = descendants(view).first(where: { $0.identifier?.rawValue == identifier }) as? T else {
            throw HistoryError.database("Missing feature control: \(identifier)")
        }
        return found
    }

    func waitUntil(_ predicate: ([LocalModelSnapshot]) -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if predicate(manager.snapshots) { view.refresh(); layout(); return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        throw HistoryError.database("Feature fixture did not reach its expected state")
    }

    func layout() { view.layoutSubtreeIfNeeded() }

    func checkLayout() throws {
        layout()
        for role in ModelRole.allCases {
            let card = try control("models.\(role.rawValue)", as: NSBox.self)
            try featureCheck(card.frame.width > 500 && card.frame.height > 50,
                             "Feature card did not fill the settings column")
            for child in descendants(card) where !child.isHiddenOrHasHiddenAncestor && child is NSControl {
                let rect = child.convert(child.bounds, to: card)
                try featureCheck(rect.minX >= -1 && rect.maxX <= card.bounds.maxX + 1 &&
                                 rect.minY >= -1 && rect.maxY <= card.bounds.maxY + 1,
                                 "Feature control overflows its card: \(child.identifier?.rawValue ?? "label")")
            }
        }
    }

    func cleanup() {
        manager.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    private func descendants(_ root: NSView) -> [NSView] {
        var children = root.subviews
        if let stack = root as? NSStackView {
            children += stack.arrangedSubviews.filter { candidate in
                !children.contains(where: { $0 === candidate })
            }
        }
        return [root] + children.flatMap(descendants)
    }
}
