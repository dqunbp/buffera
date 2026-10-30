# Versions and GitHub Releases

[English](releases.md) · [Русский](../releases.md) · [All documentation](../README.md)

The single source of version metadata is `Sources/BufferaCore/AppVersion.swift`:

- `version`: a stable `MAJOR.MINOR.PATCH` version, without `v`, suffixes or leading zeros;
- `build`: a positive integer that increases for every release, including when the version changes.

`scripts/version.sh` reads both strings, so preserve their string-constant layout. The app receives them as `CFBundleShortVersionString` and `CFBundleVersion`; MCP uses the same version directly from BufferaCore. Finder's Get Info window also displays the app version.

Increase PATCH for fixes, MINOR for features and MAJOR for incompatible major changes. Reset PATCH when increasing MINOR, and both MINOR and PATCH when increasing MAJOR. Never reset `build`. Only stable releases are supported.

## Preparation

1. Change `version` and increase `build` in `AppVersion.swift`.
2. Add change notes and installation instructions to `docs/releases/X.Y.Z.md` in all eight supported languages. Update every language in `docs/INSTALL.txt` if installation changes, and match button names to the app catalogs. See [1.0.0](../releases/1.0.0.md) for the structure.
3. Review the changes and run the relevant app checks. Verify the build and package:

   ```sh
   export BUFFERA_NOTARY_PROFILE=YOUR_KEYCHAIN_PROFILE
   zsh scripts/build-app.sh
   zsh scripts/package-release.sh
   zsh scripts/notarize-release.sh
   zsh scripts/create-appcast.sh
   zsh scripts/check-signing.sh
   zsh scripts/check-notarization.sh
   zsh scripts/check-appcast.sh
   zsh scripts/check-release.sh
   ```

   The packager refuses an `.app` whose version or build differs from the source.
   `check-release.sh` checks release restrictions in a disposable repository with a fixture GitHub CLI, without network requests or publication.
   Wait for every check to finish successfully: individual PASS lines do not establish that the entire run succeeded.

4. Commit the prepared release. Exclude local history, models, support archives and keys.
5. Create an annotated `vX.Y.Z` tag on that commit and push the commit and tag to GitHub. Example for `0.2.0`:

   ```sh
   git tag -a v0.2.0 -m 'Buffera 0.2.0'
   git push origin HEAD
   git push origin v0.2.0
   ```

## Creating and publishing a release

On an Apple Silicon Mac with Swift 6.4+, a configured Developer ID identity, an existing `notarytool` Keychain profile and an authenticated GitHub CLI:

```sh
BUFFERA_NOTARY_PROFILE=YOUR_KEYCHAIN_PROFILE zsh scripts/create-release.sh
```

The script checks that tracked files are clean, local and remote tags match the current `HEAD`, and no release with that tag exists. It then extracts **only the committed content** into a temporary folder and runs the build, packaging, DMG notarization and signed appcast generation in sequence. Untracked local files never enter the build. `--disable-sandbox` is supported in environments that prohibit SwiftPM's nested sandbox.

Results are saved under `dist/releases/vX.Y.Z/`, then a **draft** GitHub Release is created with three assets:

- `Buffera-macOS-arm64.dmg`;
- `appcast.xml`: a signed feed containing the DMG signature and embedded release notes;
- `SHA256SUMS.txt`: checksums for the DMG and appcast.

The release script explicitly uses `--build-system native`, as the UI checks do. With Command Line Tools alone, another build system can stamp the minimum macOS version in place of the SDK version, changing AppKit compatibility behavior and control geometry. Verify the final DMG, not only a local app build.

The DMG name stays constant: website and README links to `releases/latest/download/Buffera-macOS-arm64.dmg` continue working after a new latest release is published.

The app's update checker uses the public `/repos/dqunbp/buffera/releases/latest` endpoint. It compares a stable `vX.Y.Z` (or `X.Y.Z`) tag with `AppVersion.version` and offers only a newer version with a ready, nonempty `Buffera-macOS-arm64.dmg` at that tag's expected URL. Drafts, prereleases, unsupported tags, foreign URLs and incomplete assets are not offered. Rebuilding the same tag is not an update, so published releases must not be replaced. See the [guide](guide.md#updates) for UI behavior.

Open the draft on GitHub and verify its description, all three assets, DMG installation and updating from the previous version. Publish using **Publish release**, marking the release Latest. A draft does not change the public latest release. The [GitHub CLI documentation](https://cli.github.com/manual/gh_release_create) describes `--draft` and `--verify-tag`.

If the network or build is unavailable, the script exits with an error before creating a release. An asset-upload failure can leave a partial draft: inspect it on GitHub and add the missing files from `dist/releases/vX.Y.Z/`. Running the script again does not overwrite an existing release. Never replace published tags or assets; issue a new version and build for fixes.

## Signing and script constraints

`scripts/signing.sh` owns shared signing configuration for `build-app.sh`, `prepare-model-runtime.sh` and `create-release.sh`. Unconfigured builds use ad-hoc signing. For Developer ID Application, import the certificate matching the private key in your Keychain and find its SHA-1:

```sh
security import /path/to/developerID_application.cer -k "$HOME/Library/Keychains/login.keychain-db"
security find-identity -v -p codesigning
BUFFERA_SIGNING_IDENTITY=YOUR_40_CHARACTER_SHA1 zsh scripts/build-app.sh --build-system native
```

For persistent configuration, put only that SHA-1 on one line in `output/developer-id/signing-identity.txt` (the folder is ignored by Git). `BUFFERA_SIGNING_IDENTITY` takes precedence; `-` explicitly selects ad-hoc signing. Do not store a private key or password there. The chosen Developer ID identity must be valid and have a private key; otherwise the build stops before compilation. Denied key access, signing errors and timestamp failures also stop the build without falling back to ad-hoc. macOS may ask you to allow `codesign` to use the key.

Developer ID signing covers llama.cpp libraries, all three model helpers, MCP, Sparkle (Autoupdate → Updater.app → framework) and the app, working from nested components out to the enclosing package. All receive Apple's secure timestamp (requiring network access); executables also receive Hardened Runtime. No Hardened Runtime exceptions are added. `create-release.sh` passes the selected identity into its isolated build through the environment; the local configuration file and certificate are not included in the source archive. The order and options follow [Apple's instructions](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

`build-app.sh` assembles, signs and verifies the package in a temporary folder, then copies it without auxiliary attributes into `dist/Buffera.app` and verifies it again. This prevents the Documents file provider from reattaching FinderInfo during signing. The provider can still change the result's attributes later; keep the working app outside synchronized folders.

Script checks: `zsh scripts/check-signing.sh`, `zsh scripts/check-notarization.sh` and `zsh scripts/check-release.sh` (fixtures, without real keys or publication). To check a completed artifact:

```sh
codesign --verify --deep --strict dist/Buffera.app
codesign -dvvv dist/Buffera.app
```

For a Developer ID build, inspect `Authority`, `TeamIdentifier`, `Timestamp` and the `runtime` flag; check nested executables and dylibs separately. Signing does not notarize the app with Apple or install an update. Before making claims about an installed or published app's signature, verify that exact artifact. Moving from ad-hoc signing can require permission to access the existing history key again; verify continued access after updating separately, without resetting keys or history.

Keep archive creation and extraction sequential in `scripts/create-release.sh`. On macOS, `tar` can finish before consuming the archive's trailing padding, causing a `git archive | tar` pipeline to fail with SIGPIPE (141) under `pipefail`. Write the entire archive to a file first, then extract it; genuine errors in either step must stop the release. `scripts/check-release.sh` covers delayed archive padding, archive creation failure and extraction failure.

## Release notarization

`scripts/notarize-release.sh` requires Developer ID and `BUFFERA_NOTARY_PROFILE` naming an existing `notarytool` profile in Keychain. Do not add passwords, API keys or the local profile name to source control. `create-release.sh` passes the profile to the isolated build; a missing profile stops the release before building or uploading to GitHub.

The script checks the initial DMG checksum, signs the image with Developer ID and a timestamp, and submits it using `xcrun notarytool submit --wait --timeout 20m --output-format plist`. Only a successful `Accepted` response allows it to continue. `stapler` then attaches and validates the DMG ticket; `codesign` and Gatekeeper check both the image and the app mounted directly from it. The version and build inside the DMG must also match the source. The ticket is stapled to the distributed DMG; this step does not separately staple the internal `.app`. The process follows [Apple's workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Signing and stapling change the DMG bytes, so SHA-256 is recalculated after all checks and the appcast is generated last. Do not change the image after Sparkle signs it. Any notarization, stapling, signature or Gatekeeper failure stops release creation.

Apple's response, the submission ID and any available diagnostic log are retained in a separate attempt directory under `dist/releases/vX.Y.Z/notarization/`, outside the temporary build. For standalone runs the default is `dist/notarization/vX.Y.Z/`, overridable through `BUFFERA_NOTARY_LOG_DIR`. Apple may keep processing a job after a timeout: inspect its existing ID using `notarytool info`/`log` before submitting again. These local logs are not GitHub Release assets.

## Installing updates through Sparkle

`UpdateInstaller.swift` starts Sparkle 2.10.1 only from the “Update…” button. `UpdateChecker` remains responsible for background checks: the automatic-check preference, daily interval, skipped version and indicators are shared. Skipping in Sparkle's window updates the same checker. Sparkle receives no history, sends no system profile and does not install updates without user action.

`build-app.sh` bundles `Sparkle.framework` and its license and signs nested components before the app; `Package.swift` supplies the rpath. Unused XPC Services are removed because Buffera is not sandboxed. Info.plist disables Sparkle's automatic checks and installation, enables `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed`, and disables feed-signature-check expiration. `SUPublicEDKey` comes from the tracked `scripts/sparkle-public-key.txt`.

The private Ed25519 key is in the login Keychain under account `local.buffera.app`. It is separate from the Developer ID certificate; releases need both keys. Tools come from the pinned SwiftPM artifact at `.build/artifacts/sparkle/Sparkle/bin`. On another machine, import the saved key using the supported `generate_keys -x` / `-f` export/import options; do not generate a replacement for a lost key. An export is secret: keep it in secure storage outside the repository. Do not change Keychain access rules to bypass macOS authorization.

`create-appcast.sh` compares the Keychain public key with the repository and built app, checks the final DMG's SHA-256, runs the official `generate_appcast` with that account, and verifies the feed signature and version/build read from the archive. The temporary folder holds exactly one release; deltas are disabled. Generation may request Keychain access. Any error stops the release before GitHub upload.

The feed is published **in the same release** as the DMG, at `https://github.com/dqunbp/buffera/releases/download/vX.Y.Z/appcast.xml`. Publishing the draft therefore exposes both files together; no separate website deployment is needed. The installer pins the selected tag and checks the version and DMG URL. Do not edit the signed XML or DMG after generation; issue a new version. Never publish a draft without its appcast.

Sparkle's user driver repeats the version and URL check before presenting a resumed update. A previously downloaded archive or deferred installation is cancelled if it does not match the selected release. This rejection does not mark the selected release as skipped; installation remains available to retry.

The first release with the installer must be installed manually: published 0.4.0 does not contain Sparkle. Before publication, test an upgrade between two separate installed, signed builds: downloading, rejection of a damaged signature, cancellation, replacement, relaunch and preservation of history and Keychain access. Automated UI checks use a fixture installer and do not prove that app replacement succeeds. DMG notarization in the release pipeline does not establish replacement either; testing macOS policies requires upgrading between notarized builds.

Checks: `zsh scripts/check-appcast.sh`, `zsh scripts/check-release.sh`, `zsh scripts/check-signing.sh`, `zsh scripts/check-notarization.sh`, `swift run BufferaUpdateChecks` and `Buffera --updates-ui-smoke-test` in every supported language. Official contracts: [Sparkle setup](https://sparkle-project.org/documentation/), [settings](https://sparkle-project.org/documentation/customization/), [code signing](https://sparkle-project.org/documentation/sandboxing/).
