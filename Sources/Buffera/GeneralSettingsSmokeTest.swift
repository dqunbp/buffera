import AppKit
import ServiceManagement
import Carbon
import BufferaCore
import BufferaLocalization

/// Native controls with injected OS/browser boundaries: never changes login registration.
func runGeneralSettingsChecks() throws {
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw HistoryError.database(message) }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let launchEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    try check(!LoginLaunch.isLoginItem(nil) && !LoginLaunch.isLoginItem(launchEvent), "Ordinary launches must still open history")
    launchEvent.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
    try check(LoginLaunch.isLoginItem(launchEvent), "Login launch must be recognized before presenting history")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let originalButton = item.button
    item.isVisible = false
    try check(!item.isVisible && item.button === originalButton, "Hiding the icon must retain its update indicator host")
    item.isVisible = true
    try check(item.isVisible && item.button === originalButton, "Showing the icon must restore the same status item")
    let suite = "Buffera.GeneralSettings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var state = SMAppService.Status.notRegistered
    var requests: [Bool] = []
    var changes: [Bool] = []
    var failure = false
    var approvals = 0
    let preferences = AppPreferences(defaults: defaults, loginStatus: { state }, setLoginEnabled: { enabled in
        requests.append(enabled)
        if failure { throw HistoryError.database("fixture login failure") }
        state = enabled ? .enabled : .notRegistered
    }, openLoginSettings: { approvals += 1 })
    preferences.onMenuBarChange = { changes.append($0) }
    let window = SettingsWindow(appPreferences: preferences, languageDefaults: defaults, limitsDefaults: defaults,
                                themeDefaults: defaults, shortcutDefaults: defaults, frameAutosaveName: nil)
    let root = window.window!.contentView!
    func button(_ id: String) -> NSButton { descendants(root).first { $0.identifier?.rawValue == id } as! NSButton }
    let login = button("settings.launchAtLogin")
    let menu = button("settings.menuBarIcon")
    let approval = button("settings.loginApproval")
    let status = descendants(root).first { $0.identifier?.rawValue == "settings.loginStatus" } as! NSTextField
    let general = descendants(root).compactMap { $0 as? GeneralSettingsView }.first!
    try check(requests.isEmpty && changes.isEmpty && menu.state == .on && login.state == .off,
              "Opening settings must not register login or change menu visibility")
    login.performClick(nil)
    try check(requests == [true] && login.state == .on, "Login enable is disconnected")
    login.performClick(nil)
    try check(requests == [true, false] && login.state == .off, "Login disable is disconnected")
    failure = true
    login.performClick(nil)
    try check(login.state == .off && !status.isHidden && status.stringValue.contains("fixture login failure"),
              "Login failure must show an error and restore actual state")
    failure = false
    state = .requiresApproval; general.refresh()
    try check(login.state == .mixed && !approval.isHidden, "Pending approval must not claim login is enabled")
    approval.performClick(nil)
    try check(approvals == 1, "System Settings action disconnected")
    state = .notFound; general.refresh()
    try check(login.state == .off && !status.isHidden, "Unavailable login service status must be explained")
    state = .enabled; general.refresh()
    try check(login.state == .on && approval.isHidden && status.isHidden, "External status refresh is stale")
    menu.performClick(nil)
    try check(changes == [false] && !AppPreferences(defaults: defaults).showsMenuBarIcon,
              "Hidden menu preference must persist and reach the app")
    menu.performClick(nil)
    try check(changes == [false, true] && preferences.showsMenuBarIcon, "Menu icon must be recoverable")
    let url = IssueReport.url()
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let body = components.queryItems!.first!.value!
    try check(components.host == "github.com" && components.path == "/dqunbp/buffera/issues/new" &&
              components.queryItems!.map(\.name) == ["body"] && body.contains(AppVersion.version) &&
              body.contains("macOS:") && body.contains("Architecture:") && !body.contains(NSHomeDirectory()),
              "Issue draft must include only allowlisted diagnostics at the intended destination")
    try check(button("settings.reportIssue").target === SupportBuffera.reportIssue, "Issue action disconnected")
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        root.appearance = NSAppearance(named: appearance)
        root.layoutSubtreeIfNeeded()
        for control in descendants(root).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            let frame = root.convert(control.bounds, from: control)
            try check(root.bounds.insetBy(dx: -1, dy: -1).contains(frame), "General settings control overflows: \(control.identifier?.rawValue ?? control.description)")
        }
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: "/tmp/buffera-settings-general-\(L10n.language)-\(appearance.rawValue).png"))
        }
    }
}
