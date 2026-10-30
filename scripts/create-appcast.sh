#!/bin/zsh
# Generate a signed feed for this immutable release; never publish it separately.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/version.sh
SPARKLE_TOOLS="${BUFFERA_BUILD_PATH:-$PWD/.build}/artifacts/sparkle/Sparkle/bin"
EXPECTED_KEY=$(< scripts/sparkle-public-key.txt)
ACTUAL_KEY=$("$SPARKLE_TOOLS/generate_keys" --account local.buffera.app -p)
if [[ "$ACTUAL_KEY" != "$EXPECTED_KEY" ]]; then
  print -u2 'The Sparkle signing key in Keychain does not match scripts/sparkle-public-key.txt.'
  exit 1
fi
APP="$PWD/dist/Buffera.app"
for pair in "CFBundleShortVersionString:$BUFFERA_VERSION" "CFBundleVersion:$BUFFERA_BUILD" "SUPublicEDKey:$EXPECTED_KEY"; do
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :${pair%%:*}" "$APP/Contents/Info.plist")" != "${pair#*:}" ]]; then
    print -u2 "Stale or misconfigured app: ${pair%%:*}"
    exit 1
  fi
done
# package-release.sh creates this checksum after final DMG assembly.
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
FEED_WORKSPACE=$(mktemp -d "${TMPDIR:-/tmp}/buffera-appcast.XXXXXX")
trap 'rm -rf "$FEED_WORKSPACE"' EXIT
cp dist/Buffera-macOS-arm64.dmg "$FEED_WORKSPACE/"
cp "docs/releases/$BUFFERA_VERSION.md" "$FEED_WORKSPACE/Buffera-macOS-arm64.md"
"$SPARKLE_TOOLS/generate_appcast" --account local.buffera.app \
  --download-url-prefix "https://github.com/dqunbp/buffera/releases/download/$BUFFERA_TAG/" \
  --link "https://github.com/dqunbp/buffera/releases/tag/$BUFFERA_TAG" \
  --embed-release-notes --maximum-deltas 0 "$FEED_WORKSPACE"
"$SPARKLE_TOOLS/sign_update" --account local.buffera.app --verify "$FEED_WORKSPACE/appcast.xml"
# Check the actual archive metadata, not only the app beside it. Refuse stale DMGs.
[[ "$(/usr/bin/xmllint --xpath 'string(/rss/channel/item/*[local-name()="version"])' "$FEED_WORKSPACE/appcast.xml")" == "$BUFFERA_BUILD" ]]
[[ "$(/usr/bin/xmllint --xpath 'string(/rss/channel/item/*[local-name()="shortVersionString"])' "$FEED_WORKSPACE/appcast.xml")" == "$BUFFERA_VERSION" ]]
[[ "$(/usr/bin/xmllint --xpath 'count(/rss/channel/item)' "$FEED_WORKSPACE/appcast.xml")" == 1 ]]
cp "$FEED_WORKSPACE/appcast.xml" dist/appcast.xml
(cd dist && shasum -a 256 Buffera-macOS-arm64.dmg appcast.xml > SHA256SUMS.txt)
print 'Created and verified dist/appcast.xml'
