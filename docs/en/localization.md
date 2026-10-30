# Localization

[English](localization.md) · [Русский](../localization.md) · [All documentation](../README.md)

`BufferaLocalization` is the shared Foundation module for UI, models, search,
chat and errors. Translations live exclusively in
`Sources/BufferaLocalization/Resources/<language>.lproj/Localizable.strings`.
`Package.swift` declares `defaultLocalization` and SwiftPM resource processing.
`scripts/build-app.sh` copies the resource bundle into `Contents/Resources`,
declares every `.lproj` directory in Info.plist and signs the completed app.
The resource bundle is replaced in full before copying: mixing SwiftPM's flat
layout with an old `Contents/Resources` tree can make Foundation load stale translations.
Native SwiftPM lowercases regional directory names (`pt-br`, `zh-hans`), while
Xcode retains `pt-BR` and `zh-Hans`. The loader matches the bundle's actual
localizations without regard to case and opens them through `resourceURL`;
ordinary `url(forResource:)` does not find a regional directory with different casing.
`L10n.resources` explicitly loads this bundle from the app package, including
when the nested MCP binary is launched directly. An installed `.app` must not
rely on the generated `Bundle.module`: it searches the app root and then an
absolute build path, which can trigger a Documents access request.
Ordinary SwiftPM executables continue to use `Bundle.module`.

## Language selection

`LanguagePreference` stores the system mode and eight languages: Russian (`ru`),
English (`en`), Spanish (`es`), German (`de`), French (`fr`), Brazilian Portuguese
(`pt-BR`), Simplified Chinese (`zh-Hans`) and Japanese (`ja`). A missing or invalid
`interfaceLanguage` value in UserDefaults means system mode. It examines
`Locale.preferredLanguages` in order, supports regional variants and falls back
to English if none is supported. Spanish, German, French and Japanese variants
use their shared language catalog; Portuguese uses the Brazilian translation.
Chinese without an explicit script, `zh-CN`, `zh-SG` and `zh-Hans` select
Simplified Chinese. Traditional Chinese (`zh-Hant`) and TW/HK/MO regions without
explicit Hans are skipped when looking for the next supported language.
The website follows the same rules.

An explicit selection also saves `AppleLanguages` in the app's domain so native
panels use that language on the next launch. Returning to system mode removes
both overrides. Global macOS preferences are not changed.

`L10n` fixes the language for the lifetime of a launch. Changing the preference
does not recreate windows, interrupt answer generation or mix new labels with
old background messages. When the selected preference differs from the launch
preference, settings show a restart notice and a “Restart Buffera” button.
Returning to the original selection removes the notice; closing settings does
not discard a pending change.

The button uses normal app termination and `AppRelaunch`: a helper process waits
for the current PID to exit, then asks macOS to open the same `.app` with
`--show-settings`. This preserves the protection against simultaneous instances
and reopens settings in the new language. The app path is passed as a separate
argument, not inserted into shell code. If restart preparation fails, the app
stays open and displays an error. Number and date formatting takes the region
from the user's locale and the language from the interface selection; time and
date component order use localized templates.

## Strings and boundaries

User-facing literals go through `L10n.text`. Interpolation extracts values as
separate arguments, while the key contains positional `%1$@`, `%2$@` and similar
placeholders. Translators can change word order, argument text stays untranslated,
and percent signs inside arguments are not interpreted as format directives.
Percent signs in the literal itself are escaped. The original Russian template
is the key. Missing translations fall back to English, then to the source template.
Counters put a label before the number to avoid requiring noun inflection after
an arbitrary count.

`L10n.diagnostic` applies only to known native-engine messages and stored errors:
an exact catalog match allows them to be displayed in the current language.
Unknown technical details pass through unchanged. Never apply this method to
clipboard content or model answers.

Stored service titles, `HistoryStore.concealedTitle` and the locale used by
`SearchFilter.normalize` remain stable. `ClipSummary.displayTitle` translates
standard labels at display time without updating the database. User titles,
text, paths, identifiers, model settings, the MCP protocol and assistant
instructions do not depend on the interface language.

## Checks

```sh
swift run --disable-sandbox --cache-path "$PWD/.build/cache" BufferaLocalizationChecks
swift build --disable-sandbox --product Buffera
for language in ru en es de fr pt-BR zh-Hans ja; do
  .build/debug/Buffera --localization-ui-smoke-test -interfaceLanguage "$language" -AppleLanguages "($language)"
  .build/debug/Buffera --updates-ui-smoke-test -interfaceLanguage "$language" -AppleLanguages "($language)"
done
zsh scripts/check-history-panel.sh
```

Localization checks compare every catalog's keys and parameters, regional
language selection and fallback, preference saving and clearing, escaping,
and preservation of user text and metadata. The UI check uses real settings
controls with a separate UserDefaults domain and temporary folder; it does not
touch the user's history or clipboard. It checks History settings groups,
file-name selection in “Copy Differently”, reset mode and interval persistence,
key-preparation error handling and control layout in all supported languages.
A separate script checks existing panel interactions in Russian and English.

The update check uses a fixture release and isolated preferences. It checks
colored dots on the icon, the full menu-item mark in light/dark appearances and
when highlighted, tab navigation, skipping a version (including in the installer),
explicit installation, repeated clicks, startup errors, late actions after
shutdown, network errors and Updates section layout. It opens neither the network
nor the browser. `swift run BufferaUpdateChecks` checks GitHub client logic;
`--live` additionally makes a real public request.

Other standalone `swiftc` harnesses that compile app sources also need the
`BufferaLocalization` module, library and resource bundle beside the executable.
See `scripts/check-history-panel.sh` for a build example.

Check the final `.app` after moving it outside the checkout: the main binary and
`BufferaMCP --help` must find translations inside the package.
`zsh scripts/check-packaged-localization.sh` checks all languages in a separate
package under `/private/tmp`, with macOS Sandbox denying access to the source
checkout and build directory.

If a file provider keeps adding FinderInfo and prevents signing of the resource
bundle inside SwiftPM, use a build directory outside the synchronized folder:
`BUFFERA_BUILD_PATH=/private/tmp/buffera-build zsh scripts/build-app.sh --disable-sandbox`.
The panel-check script supports the same variable. For ordinary `swift build`,
use `--scratch-path /private/tmp/buffera-build` instead.

## Adding a language

Add a case with its native language name to `LanguagePreference` and provide a
complete string catalog. Checks require the catalog directories to match the
selectable languages, and all keys, positional arguments and escaped percent
signs to agree. Separate reference labels check actual resource loading.
Diagnostics recognize saved messages from every catalog; user text is never translated.

For the website, add the language to `landing/scripts/i18n.mjs` and translate
both JSON catalogs (landing page and help), the demo SVG and the Open Graph card.
Website checks cover every language. The interface language does not add OCR
languages or change the language of model answers.

## Documentation translations

The project README, website user guides, `docs/INSTALL.txt` and the release notes
in `docs/releases/1.0.0.md` are available in all eight languages.
`package-release.sh` copies the installation instructions into the DMG as
`README.txt`; `create-appcast.sh` embeds the notes for the corresponding version
in the signed feed. Editing these source documents does not change previously
published DMGs or appcasts: revised assets require a new release; existing assets
must not be replaced.

Current technical documents retain their Russian originals in `docs/`, with
full English translations in `docs/en/`. Update both versions when a contract
changes. Preserve commands, identifiers and protocol examples, and check relative
links and anchors after translating headings. The indexes are
[docs/README.md](../README.md) and [docs/README.ru.md](../README.ru.md).
Historical verification reports, early release notes and original planning notes
retain their original languages and do not establish current behavior.
