#!/bin/zsh
# Exercise notarization with disposable archives and fake Apple tools only.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/buffera-notary-check.XXXXXX")
trap 'rm -rf "$CHECK_ROOT"' EXIT
mkdir -p "$CHECK_ROOT/repo/scripts" "$CHECK_ROOT/repo/Sources/BufferaCore" "$CHECK_ROOT/bin"
cp scripts/{version,signing,notarize-release}.sh "$CHECK_ROOT/repo/scripts/"
cp Sources/BufferaCore/AppVersion.swift "$CHECK_ROOT/repo/Sources/BufferaCore/"
export NOTARY_CHECK_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567
export BUFFERA_SIGNING_IDENTITY="$NOTARY_CHECK_IDENTITY"
export BUFFERA_NOTARY_PROFILE=fixture-profile
export BUFFERA_NOTARY_LOG_DIR="$CHECK_ROOT/retained-logs"
export NOTARY_CHECK_EVENTS="$CHECK_ROOT/events.log"
cat > "$CHECK_ROOT/bin/security" <<'SH'
#!/bin/zsh
[[ "$*" == 'find-identity -v -p codesigning' ]] || exit 9
print "  1) $NOTARY_CHECK_IDENTITY \"Developer ID Application: Fixture (TESTTEAM)\""
SH
cat > "$CHECK_ROOT/bin/codesign" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == --force ]]; then
  [[ "$*" == *"--sign $NOTARY_CHECK_IDENTITY --timestamp"* ]]
  [[ "${NOTARY_CHECK_MODE:-}" != signing-error ]]
  print signed >> "${@[-1]}"
  print sign >> "$NOTARY_CHECK_EVENTS"
else
  [[ "$1" == --verify ]]
  [[ "${NOTARY_CHECK_MODE:-}" != signature-error ]]
  print "verify:${@[-1]:t}" >> "$NOTARY_CHECK_EVENTS"
fi
SH
cat > "$CHECK_ROOT/bin/xcrun" <<'SH'
#!/bin/zsh
set -euo pipefail
case "$1 $2" in
  'notarytool submit')
    [[ "$*" == *'--keychain-profile fixture-profile --wait --timeout 20m --output-format plist' ]]
    /usr/bin/grep -Fxq signed "$3"
    print submit >> "$NOTARY_CHECK_EVENTS"
    [[ "${NOTARY_CHECK_MODE:-}" != credentials-error ]] || exit 7
    if [[ "${NOTARY_CHECK_MODE:-}" == malformed-response ]]; then print malformed; exit 0; fi
    fixture_status=Accepted
    [[ "${NOTARY_CHECK_MODE:-}" != rejected ]] || fixture_status=Invalid
    [[ "${NOTARY_CHECK_MODE:-}" != timeout ]] || fixture_status='In Progress'
    cat <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict>
<key>id</key><string>fixture-submission-id</string>
<key>status</key><string>$fixture_status</string>
</dict></plist>
PLIST
    [[ "${NOTARY_CHECK_MODE:-}" != timeout ]]
    ;;
  'notarytool log')
    print '{"fixture":true}' > "${@[-1]}"
    ;;
  'stapler staple')
    print staple >> "$NOTARY_CHECK_EVENTS"
    [[ "${NOTARY_CHECK_MODE:-}" != staple-error ]]
    print stapled >> "$3"
    ;;
  'stapler validate')
    print validate >> "$NOTARY_CHECK_EVENTS"
    [[ "${NOTARY_CHECK_MODE:-}" != validation-error ]]
    /usr/bin/grep -Fxq stapled "$3"
    ;;
  *) exit 9 ;;
esac
SH
cat > "$CHECK_ROOT/bin/spctl" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ "$3" == open ]]; then
  [[ "$*" == *'--context context:primary-signature'* ]]
  [[ "${NOTARY_CHECK_MODE:-}" != dmg-gatekeeper-error ]]
  print gatekeeper-dmg >> "$NOTARY_CHECK_EVENTS"
else
  [[ "$3" == execute && "${@[-1]}" == */Buffera.app ]]
  [[ "${NOTARY_CHECK_MODE:-}" != app-gatekeeper-error ]]
  print gatekeeper-app >> "$NOTARY_CHECK_EVENTS"
fi
SH
cat > "$CHECK_ROOT/bin/hdiutil" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == attach ]]; then
  [[ "$*" == *' -readonly -nobrowse -mountpoint '* ]]
  fixture_mount="${@[-1]}"
  mkdir -p "$fixture_mount/Buffera.app/Contents"
  fixture_version="$NOTARY_CHECK_VERSION"
  [[ "${NOTARY_CHECK_MODE:-}" != stale-app ]] || fixture_version=0.0.0
  cat > "$fixture_mount/Buffera.app/Contents/Info.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$fixture_version</string>
<key>CFBundleVersion</key><string>$NOTARY_CHECK_BUILD</string>
</dict></plist>
PLIST
  print mount >> "$NOTARY_CHECK_EVENTS"
else
  [[ "$1" == detach && "$2" == */buffera-notary-mount.* ]]
  rm -rf "$2/Buffera.app"
  print detach >> "$NOTARY_CHECK_EVENTS"
fi
SH
chmod +x "$CHECK_ROOT/bin/"*
export PATH="$CHECK_ROOT/bin:$PATH"
cd "$CHECK_ROOT/repo"
source scripts/version.sh
export NOTARY_CHECK_VERSION="$BUFFERA_VERSION" NOTARY_CHECK_BUILD="$BUFFERA_BUILD"
mkdir dist

reset_archive() {
  print 'fixture archive' > dist/Buffera-macOS-arm64.dmg
  (cd dist && shasum -a 256 Buffera-macOS-arm64.dmg > SHA256SUMS.txt)
  rm -f "$NOTARY_CHECK_EVENTS"
}
expect_failure() {
  reset_archive
  if zsh scripts/notarize-release.sh > "$CHECK_ROOT/result.log" 2>&1; then
    print -u2 "FAIL: $1 was accepted"
    exit 1
  fi
  print "PASS: $1 stops notarization"
}
BUFFERA_NOTARY_PROFILE= expect_failure 'missing Keychain profile'
[[ ! -e "$NOTARY_CHECK_EVENTS" ]]
BUFFERA_SIGNING_IDENTITY=- expect_failure 'ad-hoc identity'
[[ ! -e "$NOTARY_CHECK_EVENTS" ]]
for NOTARY_CHECK_MODE in signing-error signature-error credentials-error malformed-response rejected timeout staple-error validation-error dmg-gatekeeper-error app-gatekeeper-error stale-app; do
  export NOTARY_CHECK_MODE
  expect_failure "$NOTARY_CHECK_MODE"
  if [[ "$NOTARY_CHECK_MODE" == (credentials-error|malformed-response|rejected|timeout) ]]; then
    ! /usr/bin/grep -Fxq staple "$NOTARY_CHECK_EVENTS"
  fi
  if [[ "$NOTARY_CHECK_MODE" == (app-gatekeeper-error|stale-app) ]]; then
    /usr/bin/grep -Fxq detach "$NOTARY_CHECK_EVENTS"
  fi
done
unset NOTARY_CHECK_MODE
reset_archive
ORIGINAL_CHECKSUM=$(< dist/SHA256SUMS.txt)
zsh scripts/notarize-release.sh
[[ "$(< dist/SHA256SUMS.txt)" != "$ORIGINAL_CHECKSUM" ]]
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
for expected in sign submit staple validate gatekeeper-dmg mount verify:Buffera.app gatekeeper-app detach; do
  /usr/bin/grep -Fxq "$expected" "$NOTARY_CHECK_EVENTS"
done
[[ -n "$(find "$BUFFERA_NOTARY_LOG_DIR" -name submission.plist -print -quit)" ]]
[[ -n "$(find "$BUFFERA_NOTARY_LOG_DIR" -name log.json -print -quit)" ]]
print 'PASS: accepted submission, stapled DMG, packaged-app assessment, retained diagnostics and final checksum'
