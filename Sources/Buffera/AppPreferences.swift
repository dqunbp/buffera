import AppKit
import ServiceManagement
import Carbon

/// The system owns login registration; only menu visibility is an app preference.
final class AppPreferences {
    static let menuBarKey = "showMenuBarIcon"
    let defaults: UserDefaults
    let loginStatus: () -> SMAppService.Status
    let setLoginEnabled: (Bool) throws -> Void
    let openLoginSettings: () -> Void
    var onMenuBarChange: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard,
         loginStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         setLoginEnabled: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         },
         openLoginSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.defaults = defaults
        self.loginStatus = loginStatus
        self.setLoginEnabled = setLoginEnabled
        self.openLoginSettings = openLoginSettings
    }

    var showsMenuBarIcon: Bool {
        get { defaults.object(forKey: Self.menuBarKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.menuBarKey)
            onMenuBarChange?(newValue)
        }
    }
}

/// Login launches prepare capture/indexing without opening the history window.
enum LoginLaunch {
    static func isLoginItem(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventID == AEEventID(kAEOpenApplication) &&
        event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
