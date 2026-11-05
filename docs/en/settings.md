# Application settings

Settings use a compact sidebar with navigation aligned at the top: General, AI, Appearance, History, Shortcuts, MCP, and Updates. Icons and labels have inset spacing. Appearance and history options are grouped into cards; AI brings together semantic search and the assistant. Existing actions and model checks are retained.

At the top of AI settings, a large green shield accompanies an explanation: “All models run locally. Your clipboard history is never sent anywhere.”. This applies to built-in AI features; separately authorized MCP access exposes history to connected agents.

General includes:

- **Interface language** offers System or one of the eight supported languages. Changes take effect after restarting Buffera; theme remains in Appearance.
- **Launch at login** registers the main application through `SMAppService.mainApp`. Settings read the actual macOS status when opened and when the application becomes active. Pending approval shows a mixed checkbox, explanation, and a link to system settings. If macOS cannot find the service (`.notFound`), a neutral “Could not determine launch-at-login status” message appears without assuming the app is not installed; the checkbox remains available. Errors while changing registration restore the actual checkbox state and appear inline. Registration changes only on user action; login launches prepare capture and indexing without opening history.
- **Show menu bar icon** defaults to enabled. The `showMenuBarIcon` preference persists and changes the existing `NSStatusItem` visibility. Background update checks continue, and update details remain accessible in settings. Reopening Buffera with the icon hidden opens settings; the history shortcut and settings button in history remain available.
- **Version and build** come from `Sources/BufferaCore/AppVersion.swift`; the text can be selected and copied.
- **Report an issue** opens `https://github.com/dqunbp/buffera/issues/new` in the browser. The draft contains fields for the problem, expected behavior, and reproduction steps, plus the Buffera version/build, macOS version, and executable architecture. It opens only on click; the user edits and submits the issue. History, logs, paths, user names, and device identifiers are not collected.

In Shortcuts, **Reset shortcuts** restores `⌘⌥V` / `⌘⌥C`; its behavior is unchanged.

Implementation: `AppearanceSettings.swift`, `SettingsNavigation.swift`, `GeneralSettingsView.swift`, `AppPreferences.swift`, `IssueReport.swift`, `SupportBuffera.swift`, with wiring in `AppDelegate.swift`.

Verification: `--localization-ui-smoke-test` checks the new controls and light/dark snapshots in all eight languages, visibility persistence, and login errors/approval using an injected service. Tests do not open a browser or change system registration. Existing `--shortcuts-ui-smoke-test`, `--features-ui-smoke-test`, and `--updates-ui-smoke-test` check navigation and existing actions. Synthetic checks do not establish that the installed app starts after an actual macOS logout/login.
