#!/bin/zsh
# Release plumbing checks with disposable files, no real keys or network access.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/buffera-appcast-check.XXXXXX")
trap 'rm -rf "$CHECK_ROOT"' EXIT
mkdir -p "$CHECK_ROOT/scripts" "$CHECK_ROOT/Sources/BufferaCore" \
  "$CHECK_ROOT/dist/Buffera.app/Contents" "$CHECK_ROOT/.build/artifacts/sparkle/Sparkle/bin"
cp scripts/{create-appcast,version}.sh scripts/sparkle-public-key.txt "$CHECK_ROOT/scripts/"
cp Sources/BufferaCore/AppVersion.swift "$CHECK_ROOT/Sources/BufferaCore/"
cd "$CHECK_ROOT"
unset BUFFERA_BUILD_PATH
source scripts/version.sh
export APPCAST_CHECK_VERSION="$BUFFERA_VERSION" APPCAST_CHECK_BUILD="$BUFFERA_BUILD"
export APPCAST_CHECK_KEY=$(< scripts/sparkle-public-key.txt)
mkdir -p docs/releases
print 'Fixture notes' > "docs/releases/$BUFFERA_VERSION.md"
print 'Fixture archive' > dist/Buffera-macOS-arm64.dmg
cat > dist/Buffera.app/Contents/Info.plist <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$BUFFERA_VERSION</string>
<key>CFBundleVersion</key><string>$BUFFERA_BUILD</string>
<key>SUPublicEDKey</key><string>$APPCAST_CHECK_KEY</string>
</dict></plist>
PLIST
cat > .build/artifacts/sparkle/Sparkle/bin/generate_keys <<'SH'
#!/bin/zsh
[[ "$*" == '--account local.buffera.app -p' ]] || exit 9
[[ "${APPCAST_CHECK_MODE:-}" != missing-key ]] || exit 8
if [[ "${APPCAST_CHECK_MODE:-}" == wrong-key ]]; then print wrong; else print "$APPCAST_CHECK_KEY"; fi
SH
cat > .build/artifacts/sparkle/Sparkle/bin/generate_appcast <<'SH'
#!/bin/zsh
set -euo pipefail
[[ "${APPCAST_CHECK_MODE:-}" != generation-error ]]
[[ "$*" == *"--download-url-prefix https://github.com/dqunbp/buffera/releases/download/v$APPCAST_CHECK_VERSION/"* ]]
[[ "$*" == *'--embed-release-notes --maximum-deltas 0'* ]]
feed_build="$APPCAST_CHECK_BUILD"
[[ "${APPCAST_CHECK_MODE:-}" != stale-dmg ]] || feed_build=999999
cat > "${@[-1]}/appcast.xml" <<XML
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>$feed_build</sparkle:version><sparkle:shortVersionString>$APPCAST_CHECK_VERSION</sparkle:shortVersionString>
</item></channel></rss>
XML
SH
cat > .build/artifacts/sparkle/Sparkle/bin/sign_update <<'SH'
#!/bin/zsh
[[ "$1 $2 $3" == '--account local.buffera.app --verify' ]] || exit 9
[[ "${APPCAST_CHECK_MODE:-}" != invalid-signature ]]
SH
chmod +x .build/artifacts/sparkle/Sparkle/bin/*
(cd dist && shasum -a 256 Buffera-macOS-arm64.dmg > SHA256SUMS.txt)
for APPCAST_CHECK_MODE in missing-key wrong-key generation-error stale-dmg invalid-signature; do
  export APPCAST_CHECK_MODE
  if zsh scripts/create-appcast.sh > result.log 2>&1; then
    print -u2 "FAIL: $APPCAST_CHECK_MODE accepted"
    exit 1
  fi
  [[ ! -e dist/appcast.xml ]]
  print "PASS: $APPCAST_CHECK_MODE prevents appcast creation"
done
unset APPCAST_CHECK_MODE
print 'tampered' >> dist/Buffera-macOS-arm64.dmg
if zsh scripts/create-appcast.sh > result.log 2>&1; then
  print -u2 'FAIL: modified archive accepted'
  exit 1
fi
[[ ! -e dist/appcast.xml ]]
print 'PASS: modified archive rejected'
(cd dist && shasum -a 256 Buffera-macOS-arm64.dmg > SHA256SUMS.txt)
zsh scripts/create-appcast.sh
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
print 'PASS: immutable release URL, key selection, feed verification and checksums'
