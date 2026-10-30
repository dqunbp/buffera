#!/bin/zsh
# Exercise release guards in a disposable repository; never contact GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/buffera-release-check.XXXXXX")
trap 'rm -rf "$CHECK_ROOT"' EXIT
REAL_GIT=$(command -v git)
REAL_TAR=$(command -v tar)
export REAL_GIT REAL_TAR
mkdir -p "$CHECK_ROOT/repo/scripts" "$CHECK_ROOT/repo/Sources/BufferaCore" "$CHECK_ROOT/bin"
cp scripts/{version,signing,create-release}.sh "$CHECK_ROOT/repo/scripts/"
cp Sources/BufferaCore/AppVersion.swift "$CHECK_ROOT/repo/Sources/BufferaCore/"
cat > "$CHECK_ROOT/bin/git" <<'SH'
#!/bin/zsh
if [[ "$1" == ls-remote ]]; then
  if [[ "${RELEASE_CHECK_MODE:-}" == wrong-remote ]]; then
    print "badcommit refs/tags/$RELEASE_CHECK_TAG"
  else
    print "ignored refs/tags/$RELEASE_CHECK_TAG"
    print "$RELEASE_CHECK_COMMIT refs/tags/$RELEASE_CHECK_TAG^{}"
  fi
elif [[ "$1" == archive ]]; then
  if [[ "${RELEASE_CHECK_MODE:-}" == archive-error ]]; then
    print -u2 'Fixture archive failure'
    exit 9
  fi
  "$REAL_GIT" "$@" || exit $?
  for argument in "$@"; do
    case "$argument" in --output=*|--output|-o) exit 0 ;; esac
  done
  # Valid tar padding delivered after the reader has seen the end marker.
  # The old streaming pipeline must fail even if Git's own writes win the race.
  sleep 0.05
  dd if=/dev/zero bs=65536 count=1 2>/dev/null
else
  exec "$REAL_GIT" "$@"
fi
SH
cat > "$CHECK_ROOT/bin/tar" <<'SH'
#!/bin/zsh
if [[ "${RELEASE_CHECK_MODE:-}" == extract-error ]]; then
  print -u2 'Fixture extraction failure'
  exit 8
fi
exec "$REAL_TAR" "$@"
SH
cat > "$CHECK_ROOT/bin/gh" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ "$1" == api ]]; then
  case "${RELEASE_CHECK_MODE:-}" in
    api-error) exit 7 ;;
    exists) print "$RELEASE_CHECK_TAG" ;;
    *) print v0.1.0 ;;
  esac
elif [[ "$1 $2" == 'release create' ]]; then
  print -rl -- "$@" > "$RELEASE_CHECK_CALL"
else
  exit 9
fi
SH
cat > "$CHECK_ROOT/bin/security" <<'SH'
#!/bin/zsh
[[ "$*" == 'find-identity -v -p codesigning' ]] || exit 9
print "  1) $RELEASE_CHECK_IDENTITY \"Developer ID Application: Fixture (TESTTEAM)\""
SH
chmod +x "$CHECK_ROOT/bin/"*
export PATH="$CHECK_ROOT/bin:$PATH"
export RELEASE_CHECK_CALL="$CHECK_ROOT/github-call.txt"
unset BUFFERA_SIGNING_IDENTITY
export RELEASE_CHECK_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567
export BUFFERA_NOTARY_PROFILE=fixture-notary-profile
cd "$CHECK_ROOT/repo"
source scripts/version.sh
export RELEASE_CHECK_TAG="$BUFFERA_TAG"
mkdir -p docs/releases
print 'Fixture release notes' > "docs/releases/$BUFFERA_VERSION.md"
cat > scripts/build-app.sh <<'SH'
#!/bin/zsh
set -euo pipefail
[[ ! -e local-only.txt ]]
[[ -z "${BUFFERA_BUILD_PATH:-}" ]]
[[ "$BUFFERA_SIGNING_IDENTITY" == "$RELEASE_CHECK_IDENTITY" ]]
[[ ! -e output/developer-id/signing-identity.txt ]]
[[ "$1" == --build-system && "$2" == native && "$3" == --disable-sandbox ]]
mkdir -p dist
print 'fixture DMG' > dist/Buffera-macOS-arm64.dmg
SH
cat > scripts/package-release.sh <<'SH'
#!/bin/zsh
set -euo pipefail
cd dist
shasum -a 256 Buffera-macOS-arm64.dmg > SHA256SUMS.txt
SH
cat > scripts/create-appcast.sh <<'SH'
#!/bin/zsh
set -euo pipefail
[[ "${RELEASE_CHECK_MODE:-}" != appcast-error ]]
[[ -f dist/notarized ]]
print 'fixture signed appcast' > dist/appcast.xml
(cd dist && shasum -a 256 Buffera-macOS-arm64.dmg appcast.xml > SHA256SUMS.txt)
SH
cat > scripts/notarize-release.sh <<'SH'
#!/bin/zsh
set -euo pipefail
[[ "$BUFFERA_NOTARY_PROFILE" == fixture-notary-profile ]]
[[ "$BUFFERA_NOTARY_LOG_DIR" == */dist/releases/*/notarization ]]
[[ -f dist/SHA256SUMS.txt ]]
[[ "${RELEASE_CHECK_MODE:-}" != notarization-error ]]
touch dist/notarized
SH
git init -q
git add .
git -c user.name=ReleaseCheck -c user.email=release-check@example.invalid commit -qm fixture
export RELEASE_CHECK_COMMIT=$(git rev-parse HEAD)
git -c user.name=ReleaseCheck -c user.email=release-check@example.invalid tag -a "$BUFFERA_TAG" -m fixture
mkdir -p output/developer-id
print -r -- "$RELEASE_CHECK_IDENTITY" > output/developer-id/signing-identity.txt

expect_failure() {
  local label="$1"
  if zsh scripts/create-release.sh --disable-sandbox > "$CHECK_ROOT/result.log" 2>&1; then
    print -u2 "FAIL: $label was accepted"
    exit 1
  fi
  [[ ! -e "$RELEASE_CHECK_CALL" ]]
  print "PASS: $label prevents upload"
}
for RELEASE_CHECK_MODE in wrong-remote api-error exists archive-error extract-error notarization-error appcast-error; do
  export RELEASE_CHECK_MODE
  expect_failure "$RELEASE_CHECK_MODE"
done
unset RELEASE_CHECK_MODE
BUFFERA_SIGNING_IDENTITY=- expect_failure 'ad-hoc release identity'
BUFFERA_NOTARY_PROFILE= expect_failure 'missing notarization profile'
print '// dirty' >> Sources/BufferaCore/AppVersion.swift
expect_failure 'uncommitted metadata'
git restore Sources/BufferaCore/AppVersion.swift
git tag -d "$BUFFERA_TAG" >/dev/null
expect_failure 'missing tag'
git -c user.name=ReleaseCheck -c user.email=release-check@example.invalid tag -a "$BUFFERA_TAG" -m fixture

cp Sources/BufferaCore/AppVersion.swift "$CHECK_ROOT/version.swift"
sed 's/public static let version = .*/public static let version = "01.2.3"/' \
  "$CHECK_ROOT/version.swift" > Sources/BufferaCore/AppVersion.swift
if zsh -c 'set -e; source scripts/version.sh' > "$CHECK_ROOT/result.log" 2>&1; then
  print -u2 'FAIL: malformed version was accepted'
  exit 1
fi
git restore Sources/BufferaCore/AppVersion.swift
print 'PASS: malformed version rejected'

print 'must not enter the release' > local-only.txt
export BUFFERA_BUILD_PATH=/invalid/caller/build-path
zsh scripts/create-release.sh --disable-sandbox
[[ -f "dist/releases/$BUFFERA_TAG/Buffera-macOS-arm64.dmg" ]]
[[ -f "dist/releases/$BUFFERA_TAG/appcast.xml" ]]
[[ "$(cat "dist/releases/$BUFFERA_TAG/RELEASE_NOTES.md")" == 'Fixture release notes' ]]
/usr/bin/grep -Fxq -- --draft "$RELEASE_CHECK_CALL"
/usr/bin/grep -Fxq -- --verify-tag "$RELEASE_CHECK_CALL"
/usr/bin/grep -Fxq -- "$BUFFERA_TAG" "$RELEASE_CHECK_CALL"
/usr/bin/grep -Fxq -- "$PWD/dist/releases/$BUFFERA_TAG/appcast.xml" "$RELEASE_CHECK_CALL"
(cd "dist/releases/$BUFFERA_TAG" && shasum -a 256 -c SHA256SUMS.txt)
print 'PASS: archive padding regression, exact tagged sources, isolated build, artifacts and draft-only GitHub call'
