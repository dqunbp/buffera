import BufferaLocalization
import AppKit
import BufferaCore
import BufferaModels
import CryptoKit

/// Exercises settings against temporary files without opening a window or starting a download.
func runFeatureSettingsSmokeTest() throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    try checkBackgroundPreparationPolicy()
    try checkDiscoveredModelPresentation()
    try checkUnavailableExternalPresentation()
    try checkExternalConnectionCompletion()
    try checkProbeCacheLifecycle()
    let fresh = try FeatureSettingsFixture(state: .notDownloaded)
    defer { fresh.cleanup() }
    let search = try fresh.control("models.embedding.enabled", as: NSSwitch.self)
    let assistant = try fresh.control("models.assistant.enabled", as: NSSwitch.self)
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
        let connectOwn = try fresh.control("\(prefix).connectOwn", as: NSButton.self)
        try featureCheck(!connectOwn.isHiddenOrHasHiddenAncestor && connectOwn.title == L10n.text("Подключить свою модель"),
                         "Each feature must offer its own connection flow")
        let snapshot = fresh.manager.snapshots.first { $0.descriptor.role == role }!
        try featureCheck(!status.isHiddenOrHasHiddenAncestor && !status.stringValue.isEmpty,
                         "The missing model has no visible preparation status")
        try featureCheck(!name.isHiddenOrHasHiddenAncestor &&
                         name.stringValue.contains(snapshot.descriptor.title) &&
                         name.stringValue.contains("\(snapshot.totalBytes)"),
                         "Model identity and download size are hidden before activation")
        try featureCheck(!download.isHiddenOrHasHiddenAncestor && download.title == L10n.text("Скачать модель"),
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
    try fresh.checkPresentation()

    let installed = try FeatureSettingsFixture(state: .downloaded)
    defer { installed.cleanup() }
    try installed.waitUntil { $0.allSatisfy { $0.state == .downloaded } }
    let toggle = try installed.control("models.embedding.enabled", as: NSSwitch.self)
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
    let pausedToggle = try paused.control("models.embedding.enabled", as: NSSwitch.self)
    let resume = try paused.control("models.embedding.download", as: NSButton.self)
    try featureCheck(pausedToggle.state == .on && resume.title == L10n.text("Продолжить"),
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
    try featureCheck(failureRetry.title == L10n.text("Повторить") && failure.stringValue == "Проверка ошибки загрузки",
                     "Preparation failure hides its error or recovery action")
    try featureCheck([fresh, installed, paused, failed].allSatisfy { !$0.window.isVisible },
                     "Settings checks unexpectedly opened a window")
}

private func checkDiscoveredModelPresentation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("buffera-discovery-ui-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var entries: [String: Any] = [:]
    for model in ExternalModels.supported where model.engine == .liteRT {
        let url = root.appendingPathComponent(model.filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(model.byteCount))
        try file.close()
        entries[model.filename] = ["physicalState": "ready", "storage": [
            "canonicalAbsolutePath": url.path, "expectedSizeBytes": model.byteCount]]
    }
    try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "models": entries])
        .write(to: root.appendingPathComponent(".manifest.json"))
    let fixture = try FeatureSettingsFixture(state: .notDownloaded, discovery: { ExternalModels.discover(in: root) })
    defer { fixture.cleanup() }
    let sheet = ModelConnectionSheet(manager: fixture.manager, role: .assistant,
                                     discovery: { ExternalModels.discover(in: root) })
    func control<T: NSView>(_ id: String, _ type: T.Type) throws -> T {
        func find(_ view: NSView) -> T? {
            if view.identifier?.rawValue == id, let result = view as? T { return result }
            for child in view.subviews { if let result = find(child) { return result } }
            return nil
        }
        guard let result = find(sheet.window.contentView!) else { throw HistoryError.database("Missing sheet control: \(id)") }
        return result
    }
    let next = try control("models.connection.next", NSButton.self)
    let choose = try control("models.assistant.chooseFile", NSButton.self)
    try featureCheck(!next.isHiddenOrHasHiddenAncestor && choose.isHiddenOrHasHiddenAncestor,
                     "Connection flow must start with an explanation, not file selection")
    next.performClick(nil)
    sheet.window.contentView?.layoutSubtreeIfNeeded()
    try featureCheck(!choose.isHiddenOrHasHiddenAncestor && next.isHiddenOrHasHiddenAncestor,
                     "Next must reveal only the chosen feature's file selector")
    let source = try control("models.assistant.source", NSPopUpButton.self)
    let deadline = Date().addingTimeInterval(3)
    while !source.isEnabled && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let connect = try control("models.assistant.connectSource", NSButton.self)
    try featureCheck(source.numberOfItems == 1 && source.indexOfSelectedItem == 0 && connect.isEnabled,
                     "First discovered model should be preselected without connecting")
    source.sendAction(source.action!, to: source.target)
    try featureCheck(connect.isEnabled && fixture.manager.snapshots.allSatisfy { $0.externalURL == nil && !$0.isEnabled },
                     "Browsing files must not select or enable a model")
    let supported = try control("models.assistant.supportedSources", NSTextField.self)
    try featureCheck(supported.stringValue.contains(".gguf") && supported.stringValue.contains("LiteRT-LM"),
                     "File selection must explain exact supported variants")
    // Discovery can become stale before connection. Reject the changed file and keep the dialog usable.
    for file in ExternalModels.supported where file.role == .assistant && file.engine == .liteRT {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(file.filename))
        try handle.truncate(atOffset: 0)
        try handle.close()
    }
    connect.performClick(nil)
    let status = try control("models.assistant.sourceStatus", NSTextField.self)
    let failureDeadline = Date().addingTimeInterval(3)
    while !connect.isEnabled && Date() < failureDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try featureCheck(connect.isEnabled && !status.isHidden && status.textColor == .systemRed,
                     "Rejected files must show an error and allow retry")
    try featureCheck(fixture.manager.snapshots.allSatisfy { $0.externalURL == nil && !$0.isEnabled },
                     "Rejected file must preserve the previous model")
    let origin = try control("models.assistant.sourceOrigin", NSTextField.self)
    try featureCheck(origin.stringValue == L10n.text("Найдена в Foresight"), "Selected model shows its source")
    let rescan = try control("models.assistant.rescan", NSButton.self)
    rescan.performClick(nil)
    let rescanDeadline = Date().addingTimeInterval(3)
    while !rescan.isEnabled && Date() < rescanDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try featureCheck(rescan.isEnabled && !connect.isEnabled && origin.isHidden,
                     "Refresh removes a vanished candidate and disables connection")
    var closed = false
    sheet.onClose = { closed = true }
    try control("models.connection.cancel", NSButton.self).performClick(nil)
    try featureCheck(closed, "Cancel must close the connection flow")

}

private func checkExternalConnectionCompletion() throws {
    let fixture = try FeatureSettingsFixture(state: .downloaded, enabled: true)
    defer { fixture.cleanup() }
    try fixture.waitUntil { $0.allSatisfy { $0.isReadyForUse } }
    let sheet = ModelConnectionSheet(manager: fixture.manager, role: .assistant, discovery: { [] })
    func button(_ identifier: String) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if view.identifier?.rawValue == identifier { return view as? NSButton }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let control = find(sheet.window.contentView!) else { throw HistoryError.database("Missing connection action") }
        return control
    }
    try button("models.connection.next").performClick(nil)
    var changes = 0
    var closed = false
    var busy = false
    sheet.source.onWillChange = { changes += 1 }
    let updateBusy = sheet.source.onBusyChanged
    sheet.source.onBusyChanged = { busy = $0; updateBusy?($0) }
    sheet.onClose = { closed = true }
    fixture.manager.onChange = { _ in sheet.source.refresh() }
    func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try featureCheck(condition(), "External connection did not complete")
    }
    let missing = fixture.root.appendingPathComponent("missing.gguf")
    sheet.source.selectFile(missing)
    try wait { sheet.source.connectButton.isEnabled }
    sheet.source.connectButton.performClick(nil)
    try wait { !busy }
    try featureCheck(changes == 0 && !closed && fixture.manager.snapshots.allSatisfy { $0.isReadyForUse },
                     "Rejected selection must not interrupt the working assistant or close the sheet")

    // NSOpenPanel can return /private/var/... while receipts standardize it to /var/....
    let original = fixture.manager.modelURL(for: .assistant)!
    let copied = fixture.root.appendingPathComponent("external.gguf")
    try FileManager.default.copyItem(at: original, to: copied)
    let privatePath = copied.path.hasPrefix("/private/") ? copied.path : "/private" + copied.path
    let selected = URL(fileURLWithPath: privatePath)
    try featureCheck(selected != selected.standardizedFileURL, "Fixture must exercise a noncanonical file URL")
    sheet.source.selectFile(selected)
    sheet.source.connectButton.performClick(nil)
    try wait { closed }
    let cancel = try button("models.connection.cancel")
    try featureCheck(!busy && cancel.isEnabled && changes == 1, "Successful connection must close once and release the busy state")
    let snapshot = fixture.manager.snapshots.first { $0.descriptor.role == .assistant }!
    try featureCheck(snapshot.isReadyForUse && snapshot.externalURL == selected.standardizedFileURL,
                     "Connection must enable the verified original file")
}

private func checkUnavailableExternalPresentation() throws {
    let fixture = try FeatureSettingsFixture(state: .failed)
    defer { fixture.cleanup() }
    var snapshots = fixture.manager.snapshots
    for index in snapshots.indices {
        snapshots[index].externalURL = URL(fileURLWithPath: "/Models/previous-model.gguf")
    }
    fixture.view.update(snapshots)
    fixture.layout()
    for role in ModelRole.allCases {
        let prefix = "models.\(role.rawValue)"
        let status = try fixture.control("\(prefix).status", as: NSTextField.self)
        let path = try fixture.control("\(prefix).recovery", as: NSTextField.self)
        let reconnect = try fixture.control("\(prefix).connectOwn", as: NSButton.self)
        let standard = try fixture.control("\(prefix).defaultSource", as: NSButton.self)
        try featureCheck(status.stringValue == L10n.text("Файл модели недоступен") &&
                         !path.isHidden && path.stringValue.contains("/Models/previous-model.gguf"),
                         "Unavailable external files need an explanation and original path")
        try featureCheck(reconnect.title == L10n.text("Указать файл…") &&
                         !standard.isHiddenOrHasHiddenAncestor,
                         "Unavailable external files need reconnect and standard-model recovery")
    }
    try fixture.checkPresentation(suffix: "-missing-file")
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

    init(state: ModelState, enabled: Bool = false,
         discovery: @escaping () -> [ExternalModels.Candidate] = { [] }) throws {
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
        view = ModelSettingsView(manager: manager, discovery: discovery)
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
            if card.isHiddenOrHasHiddenAncestor { continue }
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

    func checkPresentation(suffix: String = "") throws {
        layout()
        let introduction = try control("models.introduction", as: NSStackView.self)
        let privacy = try control("models.privacy", as: NSTextField.self)
        let firstCard = try control("models.embedding", as: NSBox.self)
        let document = introduction.enclosingScrollView!.documentView!
        try featureCheck(!privacy.stringValue.isEmpty && !privacy.isHiddenOrHasHiddenAncestor,
                         "AI settings must explain local processing before offering model actions")
        let introFrame = document.convert(introduction.bounds, from: introduction)
        let cardFrame = document.convert(firstCard.bounds, from: firstCard)
        try featureCheck(introFrame.maxY < cardFrame.minY,
                         "The local-processing explanation must appear before the feature cards")
        for role in ModelRole.allCases {
            let prefix = "models.\(role.rawValue)"
            if firstCard.isHiddenOrHasHiddenAncestor { continue }
            let mark = try control("\(prefix).mark", as: NSView.self)
            let heading = try control("\(prefix).heading", as: NSStackView.self)
            let toggle = try control("\(prefix).enabled", as: NSSwitch.self)
            let title = try control("\(prefix).title", as: NSTextField.self)
            let markFrame = heading.convert(mark.bounds, from: mark)
            let titleFrame = heading.convert(title.bounds, from: title)
            let toggleFrame = heading.convert(toggle.bounds, from: toggle)
            let description = try control("\(prefix).description", as: NSTextField.self)
            let descriptionFrame = heading.convert(description.bounds, from: description)
            try featureCheck(toggleFrame.minX - descriptionFrame.maxX >= 13,
                             "Description must leave a separate column and gap for the switch: \(descriptionFrame), \(toggleFrame)")
            try featureCheck(markFrame.width >= 44 && titleFrame.minX >= markFrame.maxX + 10,
                             "Feature mark must not crowd the title")
            try featureCheck(title.bounds.width >= title.intrinsicContentSize.width - 1 &&
                             toggleFrame.minX >= titleFrame.maxX + 8,
                             "The translated title must fit before the trailing enable control")
            try featureCheck(title.textColor == .labelColor && toggle.accessibilityLabel() == title.stringValue,
                             "Unavailable features need readable titles and labeled enable controls")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            layout()
            try checkLayout()
            if let bitmap = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
                document.cacheDisplay(in: document.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: "/tmp/buffera-ai-settings-\(L10n.language)-\(appearance.rawValue)\(suffix).png"))
            }
        }
        view.appearance = nil
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
