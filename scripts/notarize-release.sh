#!/bin/zsh
# Notarize the final disk image before Sparkle signs its immutable bytes.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
source scripts/signing.sh
if [[ "$BUFFERA_SIGNING_IDENTITY" == - ]]; then
  print -u2 'Notarization requires a configured Developer ID Application identity.'
  exit 1
fi
if [[ -z "${BUFFERA_NOTARY_PROFILE:-}" ]]; then
  print -u2 'Set BUFFERA_NOTARY_PROFILE to an existing notarytool Keychain profile.'
  exit 1
fi

DMG="$PWD/dist/Buffera-macOS-arm64.dmg"
[[ -f "$DMG" ]]
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
NOTARY_LOG_ROOT="${BUFFERA_NOTARY_LOG_DIR:-$PWD/dist/notarization/$BUFFERA_TAG}"
mkdir -p "$NOTARY_LOG_ROOT"
NOTARY_LOGS=$(mktemp -d "$NOTARY_LOG_ROOT/attempt.XXXXXX")
print "Notarization diagnostics: $NOTARY_LOGS"
buffera_sign_code "$DMG" archive local.buffera.app.disk-image
codesign --verify --strict "$DMG"

SUBMIT_RESULT=0
xcrun notarytool submit "$DMG" --keychain-profile "$BUFFERA_NOTARY_PROFILE" \
  --wait --timeout 20m --output-format plist \
  > "$NOTARY_LOGS/submission.plist" 2> "$NOTARY_LOGS/submission.stderr" || SUBMIT_RESULT=$?
cat "$NOTARY_LOGS/submission.stderr"
SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c 'Print :id' "$NOTARY_LOGS/submission.plist" 2>/dev/null || true)
NOTARY_STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' "$NOTARY_LOGS/submission.plist" 2>/dev/null || true)
if [[ -n "$SUBMISSION_ID" ]]; then
  print "Apple notarization submission: $SUBMISSION_ID ($NOTARY_STATUS)"
  # The status result is authoritative; unavailable diagnostics must not hide it.
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$BUFFERA_NOTARY_PROFILE" \
    "$NOTARY_LOGS/log.json" > "$NOTARY_LOGS/log.stdout" 2> "$NOTARY_LOGS/log.stderr" || true
fi
if (( SUBMIT_RESULT != 0 )) || [[ -z "$SUBMISSION_ID" || "$NOTARY_STATUS" != Accepted ]]; then
  print -u2 "Apple did not accept the submission. Inspect $NOTARY_LOGS before retrying; a timed-out job may still be processing."
  exit 1
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

# Inspect the application actually shipped, not the app beside the archive.
NOTARY_MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/buffera-notary-mount.XXXXXX")
NOTARY_ATTACHED=0
cleanup() {
  if (( NOTARY_ATTACHED )); then
    hdiutil detach "$NOTARY_MOUNT" >/dev/null || return 1
  fi
  rmdir "$NOTARY_MOUNT"
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$NOTARY_MOUNT" > "$NOTARY_LOGS/mount.log"
NOTARY_ATTACHED=1
PACKAGED_APP="$NOTARY_MOUNT/Buffera.app"
codesign --verify --deep --strict "$PACKAGED_APP"
spctl --assess --type execute --verbose=4 "$PACKAGED_APP"
for pair in "CFBundleShortVersionString:$BUFFERA_VERSION" "CFBundleVersion:$BUFFERA_BUILD"; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :${pair%%:*}" "$PACKAGED_APP/Contents/Info.plist")" == "${pair#*:}" ]]
done
hdiutil detach "$NOTARY_MOUNT" >/dev/null
NOTARY_ATTACHED=0

# Signing and stapling mutate the archive. The appcast must use these final bytes.
(cd dist && shasum -a 256 Buffera-macOS-arm64.dmg > SHA256SUMS.txt)
print 'Notarized DMG, stapled ticket and packaged application verified.'
