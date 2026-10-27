# Repository Guidelines

This file preserves verified project decisions and lessons from regressions. It is guidance, not proof that every behavior still works.

## Keeping This Guide Accurate
- Before relying on a relevant claim, inspect its owning implementation, callers, and regression tests. Prior sessions, memory, comments, and documentation are leads, not independent confirmation. For runtime claims, run the relevant check or explicitly state that only source inspection supports them.
- Distinguish intended behavior from observed behavior. If code and a documented requirement conflict, report the discrepancy; do not silently bless a regression or preserve an obsolete claim. Current user decisions take precedence over historical preferences.
- When changing behavior, update the relevant documentation and regression tests; update this file when a contract recorded here changes. Keep source paths beside non-obvious claims; remove superseded rules. Do not add speculative features, installed-version claims, or past test counts. Verify installation, signing, Git, and remote state when needed.

## Architecture & Data Integrity
Buffera is a Swift/AppKit clipboard manager for macOS 14+. `Sources/Buffera/` owns UI/clipboard integration; `BufferaCore/` owns storage; separate modules handle models, search, chat, localization, and MCP. See [docs/architecture.md](docs/architecture.md).

- Confine each `HistoryStore` to one serial queue/actor. Read AppKit pasteboard objects on the main thread; copy data before crossing queues, recheck `changeCount`, and create fresh pasteboard items on restore to prevent stale reads and capture loops.
- Block capture while the screen is locked, the session is inactive, the system is sleeping, or the session snapshot is unavailable/invalid. Discard pending pasteboard changes at session transitions and recheck eligibility after reading; keep manual pause independent. See `Sources/Buffera/ClipboardSessionMonitor.swift`, `Sources/Buffera/ClipboardService.swift`, their wiring in `Sources/Buffera/AppDelegate.swift`, and `Tests/ClipboardSessionChecks/`.
- Preserve IDs, payloads, and favorites during schema migrations; reject unknown newer schemas rather than resetting history. `HistoryStore.markUsed` changes only `sort_date`; capture/deduplication updates both dates, and neighbors use `date`. See `Sources/BufferaCore/HistoryStore.swift` and `Tests/BufferaCoreTests/`.
- Favorites are excluded from automatic count/size limits. Removing a favorite does not immediately prune history; explicit deletion can still remove it. See `Sources/BufferaCore/HistoryStore.swift` and `Tests/BufferaCoreTests/HistoryStoreTests.swift`.
- OCR and embeddings are derived data. Model failures must leave capture and literal search usable (`Sources/BufferaSearch/HybridSearchService.swift`). `Sources/Buffera/BackgroundPreparationPolicy.swift` governs background semantic indexing: battery restrictions are configurable, while Low Power Mode and thermal pauses remain enforced.

## Panel Interaction Contracts

- Automatic image thumbnails read only stored pixels or `~/Library/Caches/Buffera/Thumbnails`, never original file URLs or their metadata. File-only cache misses show a file icon; explicit preview may read the original and populate the cache. Cache entries are bounded, fingerprinted, excluded for concealed records and removed on hide/delete or maintenance. See `Sources/Buffera/ThumbnailCache.swift`, `Sources/Buffera/ClipboardService.swift`, and `Tests/ThumbnailCacheChecks/`.

Verify these contracts in `Sources/Buffera/HistoryPanel.swift`, `Sources/Buffera/HistoryShortcutGesture.swift`, and `Tests/HistoryPanelChecks/main.swift`:

- Successful and cancelled drags leave history open; only a completed copy drop counts as drag use. Subsequent outside clicks/application switches dismiss an unpinned panel unless a drag, menu, preview, sheet, filter, or introduction currently blocks dismissal.
- Escape cancels drag preparation or dismisses transient UI without also closing the panel; otherwise it closes unpinned history. Pinning prevents Escape/focus-loss dismissal, but explicit copy confirmation still closes pinned history.
- Internal clicks must not count as external. Preserve window-identity checks and deferred-dismissal tokens: AppKit button tracking and stale activation events can otherwise close a newly pinned/reopened panel.
- One shortcut tap leaves history open; cycling while holding modifiers confirms on release. Repeated taps with separate modifier holds are not that gesture.
- Reopening before the configured reset interval retains search, filters, scope, and selection. After the interval with the panel closed, opening resets to unfiltered history and its first item; an open panel never expires. `HistoryResetPreferences` defaults to enabled after one minute and is configurable in Settings; keep the manual and timed reset paths shared. See `Sources/Buffera/HistoryResetPreferences.swift` and `Tests/HistoryPanelChecks/HistoryResetChecks.swift`.

## Secrets & MCP
- Capture recognizes source markers (`org.nspasteboard.ConcealedType`, `com.agilebits.onepassword`); deduplication can also preserve an existing record's concealment. Neither is password-content detection. A Keychain prompt can arise during protected deduplication and does not prove detection (`Sources/Buffera/ClipboardService.swift`, `Sources/BufferaCore/HistoryStore+Secrets.swift`).
- Marked secrets are skipped by default. Optional storage and manual hiding encrypt payloads; unavailable keys must never cause plaintext fallback for secrets. Metadata and ordinary history are not fully encrypted.
- Keep concealed payloads out of search, OCR, chat, MCP, and logs; safe metadata may remain visible. Drag previews are masked, but an explicit user drag can transfer decrypted content (`Sources/Buffera/ClipDragController.swift`, `Sources/Buffera/AppDelegate.swift`).
- MCP is read-only: no migrations, clipboard writes, or reveal bypass. Preserve permission rechecks on success/error and concealment rechecks before returning decoded content (`Sources/BufferaMCPKit/HistoryReader.swift`, `Tests/BufferaMCPTests/`).

## Development & Verification
Follow the toolchain setup documented in [docs/guide.md](docs/guide.md#сборка-и-запуск), including sandbox and build-path workarounds when needed. Match existing four-space Swift/two-space JavaScript indentation and type/member naming. Use `L10n.text` for displayed app strings; keep English/Russian app and `landing/src/` translations aligned with behavior. Do not localize persisted identifiers/values, user content, or the MCP protocol; translate standard stored titles at display time. See [docs/localization.md](docs/localization.md).

Build: `zsh scripts/build-app.sh`; run: `open dist/Buffera.app`. Building does not update an installed copy; verify the running path when checking fixes.

Select checks for the affected modules and callers; this is a routing table, not a requirement to run every suite for every change. SwiftPM check targets are declared in `Package.swift`.

| Changed area | Checks |
| --- | --- |
| Core storage, migrations, text transformations | `swift run BufferaChecks` |
| MCP | `swift build --product BufferaMCP`, then `swift run BufferaMCPChecks` |
| Localization | `swift run BufferaLocalizationChecks`; UI smoke commands in [docs/localization.md](docs/localization.md#проверки) |
| Model management/downloads | `swift run BufferaModelChecks` |
| Embedding worker/runtime | `swift run BufferaEmbeddingRuntimeChecks` |
| Search/indexing | `swift run BufferaSearchChecks` |
| Chat orchestration | `swift run BufferaChatChecks` |
| Chat worker/runtime | `swift run BufferaChatRuntimeChecks` |
| History panel, cards, drag-and-drop | `zsh scripts/check-history-panel.sh` |
| Thumbnail cache and original-file access | `zsh scripts/check-history-panel.sh ThumbnailCacheChecks` |
| Packaged localization resource lookup | `zsh scripts/check-packaged-localization.sh` (denies access to the source checkout) |
| Clipboard session eligibility | `zsh scripts/check-history-panel.sh ClipboardSessionChecks`; capture smoke check in [docs/guide.md](docs/guide.md#проверка) |
| Copy transformations/integration | `zsh scripts/check-copy-transform.sh` |
| Website | In `landing/`: `npm run check`, then `npm run build` |
| Release scripts/packaging | [docs/releases.md](docs/releases.md) |
| Update checks, menu-bar dot and settings | `swift run BufferaUpdateChecks`; `Buffera --updates-ui-smoke-test` in RU/EN; localization checks |

Model, runtime, search, and chat suites above use fixtures by default. Real-model checks are separate: `BufferaModelChecks --download-live` downloads weights; runtime/search/chat suites support `--live` and require the paths/options documented by their `Live*.swift` entry points under `Tests/`. Choose them when validating real download/inference behavior; fixture success alone does not establish it.

For visual website review, `npm run preview` in `landing/` starts a persistent local server; it is not a terminating validation command.

Swift tests are executable harnesses, not `swift test`; register regression methods in their runners. Use synthetic data, temporary databases, and named pasteboards. Verify changed UI in both locales. Distinguish automated checks, manual observation, and unreproduced reports; passing a synthetic case does not establish reproduction of an intermittent user sequence. Listed commands are not evidence of passing: require successful completion, not just intermediate PASS messages, before reporting a check as successful or proceeding with release.

Use focused imperative commits. PRs should explain behavior, validation, limitations, and include relevant issues/screenshots. Inspect existing changes before staging; exclude local history, models, support archives, and signing material.

## Versioning & Releases
Change version/build metadata only in `Sources/BufferaCore/AppVersion.swift`: PATCH for fixes, MINOR for features, MAJOR for incompatible changes; reset lower components when increasing MINOR/MAJOR and increase `build` every release without resetting it. Preserve the string-constant layout parsed by `scripts/version.sh`.

Follow [docs/releases.md](docs/releases.md) for metadata format, preparation, checks, tags, draft publication, signing, and release-script constraints. Never replace published tags/assets; issue a new version/build.

`Sources/BufferaUpdates/` reads public GitHub release metadata without history or credentials. Keep numeric stable-version comparison, ready arm64 asset validation, persisted daily throttling/rate-limit backoff, skip-version behavior and cancellation of late results. `Sources/Buffera/AppUpdateController.swift` owns scheduling; background checks must not interrupt work. Show a quiet menu-bar dot (`BrandIdentity.menuBarIcon`) and details/actions in `UpdateSettingsView`, never an update indicator in history. Skipping hides the dot while keeping the release accessible in settings. Checks: `Tests/BufferaUpdateTests/`, `Sources/Buffera/UpdateSettingsSmokeTest.swift`. Installation remains manual.
