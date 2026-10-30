# Buffera guide

[Русский](../guide.md) · [English](guide.md) · [All documents](../README.md)

[← About the project](../../README.md) · [Download](#download) · [Controls](#controls) · [Search and answers](#search-and-answers) · [MCP](#connect-an-agent-through-mcp) · [Data storage](#data-and-limits) · [Build](#build-and-run)

The name combines the English word `buffer` and the Russian word «буфера». The brand mark is a pair of rounded outlines: monochrome in the menu bar, lilac on the app icon and in settings. The bundle, executable and modules are named Buffera; the system identifier is `local.buffera.app`.

Buffera is a local clipboard history manager for macOS 14+, built with Swift, AppKit, system SQLite and on-device text recognition through Apple Vision. External agents connect through MCP over stdio, using the official Swift SDK. Apple Silicon also supports semantic search through EmbeddingGemma 2 and built-in history chat through Gemma 4.

The interface is available in Russian, English, Spanish, German, French, Portuguese (Brazil), Simplified Chinese and Japanese. In the Appearance settings tab, choose System (the default) or one of these languages. The choice is saved immediately and takes effect after restarting Buffera. System mode selects the first supported language in your macOS preferences, falling back to English if none match. The interface language does not change history content, OCR languages or the assistant's response language. Resource organization and rules for adding strings are documented in [localization.md](localization.md).

## Download

[Download Buffera for Apple Silicon](https://github.com/dqunbp/buffera/releases/latest/download/Buffera-macOS-arm64.dmg) · [All releases](https://github.com/dqunbp/buffera/releases) · [Website](https://buffera.app/en/)

The button at the bottom of settings opens the [Tribute page](https://web.tribute.tg/d/SHI) in your browser to support development. Donations are optional and do not unlock extra features.

The prebuilt app requires a Mac with Apple Silicon and macOS 14 or later. Open the DMG and drag Buffera into Applications. Models for the optional smart features are downloaded separately in app settings.

The official Buffera 1.0.0 release is signed with Developer ID and notarized by Apple. On first launch, confirm opening the downloaded app if macOS asks. A local build's signature depends on its configuration; building alone does not perform notarization. [Apple instructions](https://support.apple.com/en-us/102445), [installation details in English and Russian](../INSTALL.txt).

In Settings → Appearance, choose the system, light or dark theme. It applies immediately to all Buffera windows and persists after restart. System mode follows the macOS appearance.

In Settings → Shortcuts, choose shared modifiers (`⌘⌥`, `⌃⌥`, `⌃⇧`, `⌘⇧` or `⌃⌘⌥`) and two different letters A–Z: open / next clip, and previous clip. Apply saves the pair without a restart; Default restores `⌘⌥V` / `⌘⌥C`. The letters refer to physical Latin-layout keys and continue working when you change the input language. If the combination conflicts with a Buffera command or registration fails, the previous pair is retained. The reverse shortcut is intercepted only while history is open. The shortcuts below are the defaults.

## Updates

Buffera checks the latest stable GitHub Release at launch, then checks hourly whether a day has passed since the last attempt. It performs the same check after the Mac wakes. Background network requests run at most once a day. When a newer version has a ready Apple Silicon DMG, two small red dots appear on Buffera's menu bar icon. A “Buffera … is available…” item with the same indicator appears in the menu and opens Settings → Updates. The history panel has no update notifications, and background checks do not open windows.

Open Settings → Updates to see the installed and available versions. Open Release opens the GitHub page with changes and downloads; Skip This Version removes the dots and menu item until the next release, while keeping the detected release accessible in settings. Check for Updates… and the automatic-check toggle are also available here; turn the toggle off to disable background requests.

The checker reads public release information without a GitHub account. Clipboard history and clip content are not sent. The detected version, skipped version and last attempt time are saved locally. A network error does not discard an update already found; the check result appears inside settings. GitHub rate limits also apply to manual checks.

Update… starts downloading and installing through Sparkle. The signed feed and DMG come from the selected GitHub release. Sparkle verifies signatures, replaces the app and restarts it after confirmation. There is no unattended background installation. If an error occurs, retry or open the release for manual installation. History, settings and downloaded models are stored outside the app bundle. Restart any connected MCP process after updating.

The previously published Buffera 0.4.0 does not include the installer. Install a release with this feature manually from its DMG once. Run the installed copy from Applications or ~/Applications, not from a mounted DMG. Update signatures do not replace Apple notarization; a complete upgrade between published versions is verified separately.

## Build and run

Command Line Tools with Swift 6.4 or later are required by the MCP SDK's currently pinned transitive dependencies. The built app still supports macOS 14. Full Xcode is optional. Direct SwiftPM dependencies are `modelcontextprotocol/swift-sdk` version `0.12.1` and Sparkle `2.10.1`; resolved dependency versions are stored in `Package.resolved`.

```sh
zsh scripts/build-app.sh
open dist/Buffera.app
# Package the built arm64 app as a DMG:
zsh scripts/package-release.sh
```

The app version, build number and MCP version are defined in `Sources/BufferaCore/AppVersion.swift`. Release tags use `vX.Y.Z`. The command `zsh scripts/create-release.sh` builds the tagged code and creates a draft GitHub Release with a DMG, signed `appcast.xml` and SHA-256 checksum. Tag preparation, publication and recovery from errors are documented in [releases.md](releases.md).

If your environment prohibits nested `sandbox-exec`, pass `--disable-sandbox` to the build script. This only disables the SwiftPM manifest sandbox, not the app's macOS protections.

The result is `dist/Buffera.app`, containing the main app and a separate `Contents/MacOS/BufferaMCP` executable. Without signing configuration it uses an ad-hoc signature. For Developer ID, set the certificate SHA-1 through `BUFFERA_SIGNING_IDENTITY` or the local `output/developer-id/signing-identity.txt`, as described in [signing](releases.md#signing-and-script-constraints). On Apple Silicon, the build also downloads a pinned llama.cpp release, verifies its SHA-256 and bundles the engine with `BufferaModelProbe` for model checks, `BufferaEmbeddingWorker` for search and `BufferaChatWorker` for chat. sqlite-vec 0.1.9 is built statically from pinned source. Model weights are not bundled. Distribution without an unidentified-developer warning requires Developer ID and notarization. You can copy the app to Applications. For launch at login, add it under System Settings → General → Login Items.

If Documents is managed by a file provider, it may restore FinderInfo attributes on the built `.app`, causing strict signature verification to fail. The script signs the bundle in a temporary directory and copies it to `dist` after verification. Run the working copy outside the synchronized directory, for example from `~/Applications/Buffera.app`. Copy without auxiliary attributes using `ditto --norsrc --noextattr dist/Buffera.app ~/Applications/Buffera.app`, then run `codesign --verify --deep --strict ~/Applications/Buffera.app`. This copy retains Developer ID signing; do not re-sign it ad-hoc.

Before launching, quit Pasta if it occupies `⌘⌥V`. Buffera does not paste automatically or request Accessibility permission to synthesize keystrokes. macOS may separately request clipboard access; allow it for background history capture.

## Search and answers

Settings → Search and Answers independently enables Semantic Search and Ask Buffera. Each feature card shows its purpose, model name and size: EmbeddingGemma 2 is about 310 MB for search; Gemma 4 E2B is 2.84 GB for the assistant. Start explicitly with Download and Enable. Once the download and validation finish, the feature enables automatically; an already prepared model can be reused with the ordinary toggle. Downloads can be paused and resumed, including after restart. Disabling a feature retains its model; Remove Model frees the space. Details contains the license and checks using built-in examples.

Enabling semantic search starts gradual preparation of history text and OCR. The feature card shows progress, partially processed long clips and an option to retry after an error. Disabling it stops processing and frees memory; files and the index remain for later resumption.

In history, Include semantic search adds semantic results to literal matches while preserving every filter. Semantic search starts at three characters after trimming whitespace and newlines at the edges; one- or two-character queries use literal search only. Literal matches appear first, followed by up to 200 semantic additions. Clearing the checkbox uses literal matches only. The status is “Searching by meaning…” for semantic search and “Finding text matches…” for literal search. An empty query shows history with “Loading history…”; if the model is disabled or unavailable, ordinary search remains usable. Concealed content is not indexed, and files on disk are not opened.

The semantic index covers visible text, links, file paths and image OCR. A long clip contributes up to 128 KiB of text and 32 chunks of 512 tokens, with a 64-token overlap; incomplete processing is indicated in progress. Original content is retained. Storage, versioning and engine details are in [models.md](models.md).

Background preparation for semantic search pauses on battery by default. The card shows the reason, progress and Continue Now; plugging in power resumes the queue automatically. Search over prepared clips and assistant questions remain available. You can disable the “only on external power” restriction; macOS Low Power Mode and high thermal pressure also pause background computation. See [battery use and queue management](models.md#battery-use).

## Ask Buffera

Ask beside the semantic-search checkbox and the Ask Buffera… menu item open a local language model (LLM) with access to clipboard history. In Settings → Search and Answers, choose Download and Enable, or enable the feature if its model is already downloaded. Semantic search is enabled independently; without it, the assistant searches by words.

For example, ask “What connection error did I copy yesterday?” or “What was next to this clip?” The assistant searches, reads the results and retrieves nearby copies when needed. Its answer appears gradually. Source buttons below the answer show the app and copy time; clicking one opens the clip among its neighbors without changing the clipboard.

Enter sends a question; Shift+Enter adds a line. Stop or Escape during an answer cancels generation. Closing the window also stops the answer but keeps the conversation until Buffera quits; New Conversation clears it. Conversations are not written to disk. Concealed clips do not enter chat; hiding or deleting a source resets the associated conversation. Built-in chat does not need the permission for external MCP agents.

Answers use a limited set of retrieved clips, not a complete analysis of all history. Long documents and answers may be truncated, with a notice in the interface. File paths are read as text; the files themselves are not opened.

## Controls

Thumbnails are stored in `~/Library/Caches/Buffera/Thumbnails` (up to 64 MB and 512 files). At launch and when opening history, Buffera uses this cache or image bytes stored in history without accessing original files. If a clip contains only a path and has no cached thumbnail, a file icon appears. Explicit preview with Space or `⌘Y` may open the original and request access to its folder; the resulting thumbnail is cached for later launches. Concealed clips are not cached; hiding or deleting a clip removes its thumbnail. The cache is safe to delete: thumbnails from stored image bytes regenerate automatically, while path-only clips require opening preview again.

Drag cards into other apps: text and links into editors and input fields, images and files into upload areas, chats and Finder. The full content and all saved formats are transferred, including RTF/HTML and app-specific data; multiple objects in one clip remain separate objects. Images also receive temporary files that remain available to the receiving app after the drop ends. Format support depends on the receiver; accepting `⌘V` does not guarantee drag-and-drop support.

Dragging only copies: original files and the history record stay in place, and the general clipboard is unchanged. Original files and folders must be available at their saved paths; if any are unavailable, the entire operation is cancelled with a message. Concealed clips use neutral previews without their content. Escape, releasing the mouse before preparation finishes and rejected drops do not reorder history. An accepted drop counts as use while preserving the original copy date.

The pin icon to the right of search pins the window above other apps when you switch between them. Click it again to restore ordinary automatic dismissal. `⌘⌥V` first returns focus to pinned history, preserving the query, selection and list position. Escape and switching apps do not close a pinned window; explicit copy confirmation does. Pinning itself lasts until Buffera quits. Revealed text is masked again when you switch to another app.

| Action | Keys |
| --- | --- |
| Open history / next item | `⌘⌥V` |
| Previous item while the window is open | `⌘⌥C` |
| Move between list or grid rows | `↑` / `↓` |
| Move between adjacent cards outside the search field | `←` / `→` |
| Copy the selection to the clipboard and close | `Enter` or double-click |
| Immediately select one of the first nine items in the current list | `⌘1`–`⌘9` |
| Preview the selected clip | `Space` with list focus; `⌘Y` also works from search |
| Add to / remove from favorites | `⌘D` |
| Show nearby clips by copy time | `⇧⌘N` |
| Conceal content / temporarily reveal it | `⇧⌘H` |
| Show an image in Finder | `⇧⌘R` |
| Save an image to a chosen folder | `⇧⌘S` |
| Focus search | `⌘F` |
| Switch focus between search and cards | `Tab` |
| Show / hide the filter sidebar | `⌘⌥S` |
| Open Appearance settings | `⌘,` |
| Clear query and filters and return to all history | `⌘0` |
| Cancel without changing the clipboard | `Esc` |
| Delete the selected clip | `⌘⌫` |

A single `⌘⌥V` press activates Buffera and opens the window with focus on the cards. If you release the keys immediately, the window stays in ordinary mode: subsequent `⌘⌥V/C` presses only move the selection and do not activate automatic closing until the next opening. For quick cycling, keep holding `⌘⌥` continuously from opening and press V or C again: V selects the next clip, C the previous one. Releasing `⌘` or `⌥` after cycling copies the selection and closes the window. Opening from the menu or app icon also uses ordinary mode; auto-repeat from holding V itself does not enable cycling. In a grid, `↑/↓` move one row up or down and `←/→` move to the adjacent card. Enter, the card's Copy button or a double-click confirms the clip, places its content on the system clipboard and closes the window, returning focus to the previous app. Paste in the destination app yourself (usually with `⌘V`; Buffera does not change your key remappings). In an unpinned window, Escape or switching apps closes it without confirmation; Escape also cancels a confirmation that has not finished. In preview and nearby mode, Escape first returns to the previous level.

After a successful selection, the clip moves to the top without a duplicate; its copy date, source app, favorite status and concealment are retained. That clip is selected the next time ordinary history opens. Escape and switching apps preserve the selection without copying or reordering. A new external copy, including a repeated copy, becomes first and selected if it matches the current filters; otherwise, the filtered list keeps its selection.

Start typing with list focus to start a new search. `⌘F` focuses the existing query for editing; spaces in the search field remain ordinary spaces. Reopening soon preserves the query, filters, History/Favorites scope and selected clip. By default, after one minute with the window closed, the next opening shows an empty search, all history without filters and the first clip. An open window never resets. In Settings → History, disable this reset or set a delay from 1 to 1440 minutes; changes apply immediately. Restarting the app also resets window state. Return to all history with the reset button beside search or `⌘0`.

You can also open history from Buffera's icon in the system menu bar. Its menu shows the status of `⌘⌥V`; if there is a conflict, it offers a retry for shortcut registration. Ordinary `⌘C` copying remains available in the search field.

Cards use a list or grid. Hide the sidebar containing types, dates and apps with the button left of search or `⌘⌥S`. Active filters remain applied, and type, date and app remain accessible from the filter icon beside search. Each card contains content, source app, date and actions: favorite, preview, copy, and concealment or export when applicable. Buttons are always visible, without hovering. Tooltips show action names and shortcuts; the context menu contains the same actions plus deletion. Holding `⌘` shows numbers on the first nine clips for quick selection. An outline marks the selected card. Starring updates the card in place; removing a star in Favorites removes only that clip from the view.

Set a favorite clip's label with right-click → Label…, for example “Home Wi-Fi password.” The label, up to 120 characters, appears above the content even for a concealed clip; the password itself stays masked. An empty field removes the label. Labels survive restart, recapture and removal from favorites. They are unencrypted metadata: do not put the secret itself in a label. Labels are excluded from content search and are not sent to MCP or chat.

The From Devices type shows new clips marked as Universal Clipboard; cards label them From Another Device. The remote device and app names are unknown, and no Mac app is assigned to them. Concealed shows both automatically marked and manually hidden clips. From Devices and Concealed share the type selector with text, links, images, files and data. One type is selected at a time and combines with search, date, app and Favorites. Old clips are not retroactively marked as remote because earlier versions did not save that property.

Space or the card's preview button opens a temporary preview beside the list. It can show long text, an image, file paths or a list of other formats. Space and Escape close preview, Enter selects the clip, and the arrow keys return to the list and change the selection. Merely hovering does not reveal full text. Explicitly reveal a concealed clip first with Reveal Content.

Copy Differently is a submenu opened by right-clicking a card. The card button and `⇧⌘C` open the same list. Choosing an action immediately copies the result and closes history. There is no extra window or confirmation; `Esc` closes the menu without copying.

Only applicable options appear: Plain Text for readable text, Format JSON for valid JSON that needs formatting, Unwrap Lines for adjacent nonempty lines, Remove Duplicate Lines when duplicates exist, and Remove Tracking Parameters for a link with removable tags. Images offer Text from Image through existing OCR; if completed recognition found no text, the option is hidden. Opening the menu does not start recognition. These actions are unavailable for concealed clips.

Options are checked against the full content in the background; Checking Options… may appear briefly on first opening. Each option operates on the original content. Text and links also offer As .txt File and As .md File: the complete text is written as UTF-8 without content changes, and a file is placed on the clipboard for pasting into Finder or apps that accept attachments. Choose its name in Copy Differently → Text File Name: the first nonempty line (default), or the copy date and time. Leading Markdown heading markers and invalid characters are removed, long names are shortened, and the date is used if no suitable name remains. Files from different clips with the same name do not overwrite each other. They use the temporary export cache with age and size cleanup. Other options copy plain-text results; the clip's original formats, copy date, source, favorite status and concealment remain unchanged. As with ordinary copying, the clip moves to the top without creating a duplicate.

JSON formatting changes whitespace and indentation only: large numbers, duplicate keys and escaping are retained. Line-break cleanup preserves paragraphs; deduplication keeps the first occurrence of each line in order and preserves blank lines. Cleanup of a single HTTP(S) URL removes `utm_*`, `fbclid`, `gclid`, `dclid`, `msclkid`, `yclid`, `mc_cid`, `mc_eid`, `gbraid` and `wbraid`; other parameters and the fragment remain unchanged. A URL with a recognized signature is not changed if removing tags could invalidate it.

On error, history stays open and the clipboard is unchanged. During processing, `Esc` cancels the pending copy. Text transformations have a 2 MiB input/output limit and a JSON depth limit of 128; Plain Text reads the complete text without that limit. OCR that reached the 200,000-character limit is not presented as a complete result. These actions require neither models nor the network.

What I Copied Before and After opens from the clock button on a card, its context menu or `⇧⌘N`. It shows the anchor clip and up to 10 nearest copies on either side, newest first. Neighbors come from all history: the query, type, date range, app and Favorites scope temporarily stop restricting the list. Concealed clips remain masked. When opened, the anchor is centered in the visible area as far as the list boundaries allow. A colored dot and outline mark it even after you select a neighbor; repeat the action on another clip to continue through history.

Back to History or `Esc` restores the original query, filters, selection and scroll position. If preview is open, the first `Esc` closes it and the next returns to results. New copies do not reorder neighbors while you view them; results refresh if necessary when you return. Closing the window ends the temporary mode, and the next opening restores the original search. Neighbors are ordered by the last external copy, not by selecting a clip in Buffera. Recapturing identical content replaces its previous date and source; there is no complete log of every repetition. This feature also works on old history without models or a database migration.

The gear to the right of search, `⌘,` and Settings… in the system menu open a separate settings window. Appearance, History, Shortcuts, MCP, Search and Answers, and Updates group settings by purpose. History has three sections: storage (limits and data folder), secrets and window-opening behavior. Resetting search and filters does not delete saved clips. The text-export filename setting is in Copy Differently → Text File Name on a clip's menu. The choice is saved for future exports and does not itself copy anything. Opening settings again raises the same window; closing it does not quit the app. Appearance and limit changes apply immediately; language changes require a restart. Shortcuts are saved with Apply; other settings save immediately. History can use a regular window or a panel at the left or right screen edge. Drag the regular window by an empty area and resize it at its edges; its position and size are saved separately from side-panel width. A panel fills the available screen height, can be resized horizontally and appears immediately at the selected edge without an opening animation. On closing it slides offscreen; the system's Reduce Motion setting disables this animation. Standard close, minimize and zoom controls are hidden. Escape closes an unpinned window, while confirming a clip closes even a pinned window.

Choose 1–4 columns and a density of 3–12 visible rows. One column gives a list; multiple columns give a grid. Cards in a regular window have equal heights of at least 96 points. In side panels, height depends on content: short text starts at 74 points, while long text grows up to the height specified by density. Images retain room for the thumbnail and actions, and cards in the same grid row match its tallest card. Minimum card width is 230 points, so a narrow window may show fewer columns. Window size is constrained to the visible screen area; disconnecting a monitor moves a regular window back to an available screen. The background uses system translucency and blur while text remains opaque. Its appearance depends on the theme and the system's Reduce Transparency setting.

## Included features

- Captures new copies every 400 ms while the app is running and the Mac session is available. Locking, switching users or sleeping pauses capture; copies accumulated then are skipped on return, and a manual pause stays in effect.
- Saves available binary representations of every item, including text, RTF, PNG/TIFF, links, groups of files and custom formats.
- Recapturing identical content moves the existing clip to the top and replaces the date and app with the latest copy's details. Concealment and favorite status are retained.
- Case-insensitive search for every query word across text fragments, recognized image text, filenames and app names. `%` and `_` are treated literally. Semantic search is optional; its setup is described above.
- A sidebar with types, date ranges and apps. The compact filter menu beside search also works with the sidebar hidden; Reset Filters clears them together while preserving the search query.
- The calendar popover offers All Time, Today, Yesterday, 7 Days, 30 Days and two calendars for the range boundaries. The final selected day is included in full; reversed date ranges are corrected automatically. Seven- and thirty-day ranges include today, using the macOS local time zone.
- The app filter selects the exact source name of the last copy from existing history and combines with text, type and date. Names are sorted case-insensitively. Buffera itself is omitted from the source list, but its clips remain in all history. The source comes from pasteboard metadata when available; otherwise, the frontmost app is used.
- The card's star adds a clip to Favorites. Favorites combines with search and every filter; clips survive restart and are protected from automatic history cleanup.
- Pages of 150 clips loaded as you scroll. Full binary payloads are read separately from the list.
- PNG/TIFF can be exported as PNG: Save As… creates a permanent file at a chosen location; Show in Finder creates a temporary file with automatic cleanup.
- Marked confidential clips are skipped by default; encrypted storage shows them behind dots. Ordinary text or links can be concealed manually. Show temporarily reveals the selected concealed clip's content.
- Pause capture from the menu, delete individual clips, and set count and size limits in Settings → History.

## Initial setup

On first launch, a separate setup window walks through language and theme, history window, main shortcuts, storage, MCP, search and answers. Any step can be skipped. Set Up Later or closing the window cancels the entire draft. Reopen the wizard with Set Up Buffera… in the menu or Run Setup Again… at the bottom of Settings → Appearance.

Until Apply and Start, MCP permission and model settings remain unchanged and downloads do not begin. Skipping a step during repeat setup preserves its previous values. A new language takes effect after restart; the theme applies when setup finishes, with a preview inside the wizard.

Semantic-search setup is available below the search field even when the model is disabled. During download and preparation, its status remains visible while ordinary search continues working. The first use of What I Copied Before and After opens an explanation in a separate window. After confirmation, a distinct mode heading, anchor marker and return button appear. Reopen the explanation with the “?” button.

## Connect an agent through MCP

1. Open Settings → MCP and enable Allow Agents to Read History. Access is off by default.
2. Full commands for Claude Code and Codex, plus JSON configuration, are displayed. Click Copy beside the required block; the nearby confirmation identifies what was copied. Run the command in Terminal or add the JSON to your agent's settings. Every option includes the absolute path to `BufferaMCP` inside the running app bundle; copy it again after moving the bundle.
3. Reconnect MCP in your agent. It starts the executable itself and communicates over stdin/stdout, without a network port or separate continuously running service.

The agent receives three tools: `search_history` for combined literal and semantic search with filters, `read_clip` to read a clip, and `get_neighbors` for nearby copies. Search uses the enabled embedding model and prepared portion of the index; without them it searches by words. Concealed clips appear in search and neighbors with the literal title `Скрытая запись` (“Concealed item”), with date, app and other metadata but no text snippet or size. They can be found through metadata, never through concealed text, OCR or semantic vectors. `read_clip` also returns a mask.

Concealed content is unavailable through MCP, including direct tool calls. Reveal a clip only in Buffera's interface. After updating the app, restart the connected MCP process so it uses the new tool set.

All tools are read-only: MCP does not change history, clip order or the system clipboard. Text and links are read from their complete stored content; images expose only existing OCR, and files expose only stored paths without reading files from disk.

Disable access in the same tab; already running processes recheck permission on every request. You can copy configuration before granting access, and copying does not enable it. Buffera does not modify external agents' settings. Permitted clip content enters the chosen agent's context, and further processing depends on that agent.

After launching Buffera once and enabling access, MCP can read saved history even while the app is closed. New copies and OCR are added while Buffera itself runs. Embeddings and the built-in chat model are not required to connect. Tool parameters, response limits and diagnostics are documented in [mcp.md](mcp.md).

## Search text in images

New and previously saved PNG/TIFF image clips are recognized in the background sequentially, one image at a time. [Apple Vision runs on the device](https://developer.apple.com/documentation/vision/recognizing-text-in-images), without sending images over the network. It uses accurate mode with automatic language detection; Russian and English are selected from the languages available in the installed macOS version. Support depends on the OS version.

Recognized text supplements ordinary search and is stored separately, up to 200,000 characters per clip. The original image and its formats remain intact: selecting a result still copies the image. Images are resized to a maximum of 4096 pixels on the long edge, respecting orientation. The first frame or page of each pasteboard item is processed; PNG and TIFF representations of the same item are not duplicated. File references are not opened, and file contents on disk are not recognized.

An image with no text counts as processed. A failure does not block the rest of the queue: Retry Recognition in the Buffera menu retries failed attempts, which are also retried at the next launch. Progress is shown in the same menu. Concealed clips are not recognized or searched through OCR; concealing an already processed clip removes its recognized text from the index.

## Data and limits

On the first launch after the rename, the app moves the entire previous history directory, including SQLite WAL, backups and saved exports, and copies preferences to the new system domain. Migration only runs after the previous version closes. Existing new preferences take precedence; if both history directories exist, the app reports an error without merging or overwriting anything. Old preferences remain available for recovery.

History is stored in `~/Library/Application Support/Buffera/`: `history.sqlite`, SQLite auxiliary files and separate `mcp-access.json` permission. The current schema version is 10. Databases at versions 0–9 are upgraded automatically in one transaction: missing concealment, favorite and remote-origin fields, a separate OCR table, last-use ordering, semantic-index tables, encrypted-payload encoding and secret-maintenance data, and favorite labels are added. Initial ordering matches copy dates, so migration does not reorder clips. Ordinary images from older history enter the recognition queue; semantic indexing only begins after enabling the embedding model. Existing IDs, clips and original content are retained. An unknown newer schema is not downgraded.

The Data type groups formats without dedicated recognition: internal app objects and some standard representations without a supported text or image alternative. Available original formats are retained for pasting back; Space shows their list.

Show in Finder creates a PNG in the system temporary directory `$TMPDIR/local.buffera.app/ImageExports/`. Showing the same image again refreshes its temporary file and retention time. Files older than 24 hours since their last reveal are removed at launch, hourly while Buffera runs, and on a new export. Above 256 MiB, the oldest files are removed while retaining the current export. macOS may also clear the temporary directory. Temporary exports from the previous installation continue to be cleaned under the same rules.

For a permanent file, use Save As… or copy the temporary image to your own folder; Buffera cleanup does not affect an independent copy. The original image remains in history within its limits. The `~/Library/Application Support/Buffera/Exports/` directory created by an earlier version and migrated with history is not cleaned automatically.

Set limits in Settings → History. Defaults are up to 50,000 ordinary clips and 5 GB of serialized content. Both limits are enforced in a transaction after a new copy, removing clips from the end of ordinary history by last copy or selection time. Favorites do not count toward these limits and are not removed automatically, so total history size may exceed the configured limit. Removing a star does not itself delete anything; the clip becomes eligible for cleanup on the next copy. Explicit deletion also works for favorites. The size limit counts original content; OCR, semantic vectors and downloaded models take extra space. The SQLite file itself may remain larger after deletion because free pages are reused. Exported images are outside the history limit: temporary exports have their own limits, while permanent files remain until you delete them.

One clip is limited to 64 MB of original representations; indexed text is limited to 200,000 characters. Content is otherwise retained in full within the 64 MB limit. Last Error… in the menu reports skipped captures or errors. The clipboard content present before launch is not imported automatically.

Settings → History → Secrets in History offers two modes: Do Not Save Secrets (default) and Save Secrets Encrypted. Secrets are identified by the markers `org.nspasteboard.ConcealedType` and `com.agilebits.onepassword`. In the first mode, Buffera skips the entire group before reading content; in the second, it encrypts all representations. Ordinary clips retain their existing storage behavior.

The list shows dots and a lock. A secret's content does not enter its title, search, OCR, semantic index or MCP. You can find the clip through a safe title, app and date; these metadata remain unencrypted. Show temporarily reveals text inside Buffera, while copying restores the original formats with a confidentiality marker.

If the source app does not mark a password, it is saved as ordinary text; Buffera does not detect passwords from their content. Hide for saved text or a link encrypts the payload and removes plaintext and indexes regardless of capture mode. When the key is available, recapturing the same payload retains its secrecy. If the key is unavailable, new unmarked clips are handled as ordinary content; marked data is never stored in plaintext.

Encryption uses AES-256-GCM with a fresh nonce for every write. A random key lives in macOS Keychain with access for the main app; MCP does not receive the key. If Keychain access fails, the secret is skipped with an error, without falling back to plaintext storage. macOS may ask for permission to access the key, especially after updating an app with a temporary ad-hoc signature. Losing the key makes saved secrets unrecoverable.

Switching to Do Not Save affects new copies; existing secrets remain encrypted and available inside Buffera. Old concealed clips are encrypted automatically at launch; if the key cannot be accessed, they stay unavailable for reveal until a successful retry. Retry by choosing encrypted storage in settings. When a plaintext clip becomes a secret, SQLite cleans old pages and WAL; if another process holds a database snapshot, cleanup is deferred to a later attempt. This does not alter old backups or disk snapshots.

Clips with `TransientType` or `AutoGeneratedType` are skipped. A confidentiality marker invokes the chosen secrets mode.

Files are stored as references to originals, not backups. Deleted or moved originals cannot be restored. Deferred file promises and data withheld by the source app are not yet materialized into standalone files. Such a clip may be skipped with a message. Not every app-specific format has been tested.

## Checks

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
swift run --cache-path "$PWD/.build/cache" BufferaChecks
swift build --product BufferaMCP
swift run --cache-path "$PWD/.build/cache" BufferaMCPChecks
swift build --product Buffera
.build/debug/Buffera --smoke-test
.build/debug/Buffera --ocr-smoke-test
```

The smoke check uses a separate named system pasteboard and does not modify your main clipboard. `--ocr-smoke-test` exercises real Vision on synthetic images, search in a separate temporary database and the background queue; it does not read your history or clipboard. A restricted execution environment may block Vision, so run the OCR check in an ordinary user environment. These checks require neither XCTest nor full Xcode.

`zsh scripts/check-copy-transform.sh` checks text transformations and `.txt`/`.md` file copying through a separate test pasteboard.

`zsh scripts/check-history-panel.sh` checks the panel in two locales, cards and drag-and-drop. Pass `ClipDragChecks` to run a single suite. After building, `.build/localized-panel-checks/ClipDragChecks --interactive` opens a separate harness with the real panel, synthetic clips, a native editor and a local web form. The `Delay preparation 2s` checkbox lets you test releasing the mouse and pressing Escape before data is ready. The harness does not use your history or write the general clipboard; drop results are also logged to `/tmp/buffera-drag-ui.log`.

Manual check: copy text, an image and several files; open the window and release the keys (it should remain open); move with the arrow keys and press Enter (it should close), then paste into the original app. Reopen with `⌘⌥V`, keep holding `⌘⌥`, press V/C again and release the modifiers: the selected clip should be copied and the window should close. Separate single presses with a release after each should not close the window. Scroll down, close and reopen: clips should appear without a flash of an empty list; a cold opening waits for data and card layout. Check card actions and their tooltips, `⌘1`–`⌘9`, preview with Space and `⌘Y`, favorites after recapture and restart, search retention between openings and explicit reset with `⌘0`. Check Escape, the app filter, calendar, temporary export, Save As… and concealment/temporary reveal using synthetic content. Completed checks and their limitations are recorded in [verification.md (Russian)](../verification.md).
