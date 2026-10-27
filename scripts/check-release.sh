#!/bin/zsh
# Exercise release guards in a disposable repository; never contact GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/buffera-release-check.XXXXXX")
trap 'rm -rf "$CHECK_ROOT"' EXIT
REAL_GIT=$(command -v git)
export REAL_GIT
mkdir -p "$CHECK_ROOT/repo/scripts" "$CHECK_ROOT/repo/Sources/BufferaCore" "$CHECK_ROOT/bin"
cp scripts/{version,create-release}.sh "$CHECK_ROOT/repo/scripts/"
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
else
  exec "$REAL_GIT" "$@"
fi
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
chmod +x "$CHECK_ROOT/bin/"*
export PATH="$CHECK_ROOT/bin:$PATH"
export RELEASE_CHECK_CALL="$CHECK_ROOT/github-call.txt"
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
[[ "$1" == --disable-sandbox ]]
mkdir -p dist
print 'fixture DMG' > dist/Buffera-macOS-arm64.dmg
SH
cat > scripts/package-release.sh <<'SH'
#!/bin/zsh
set -euo pipefail
cd dist
shasum -a 256 Buffera-macOS-arm64.dmg > SHA256SUMS.txt
SH
git init -q
git add .
git -c user.name=ReleaseCheck -c user.email=release-check@example.invalid commit -qm fixture
export RELEASE_CHECK_COMMIT=$(git rev-parse HEAD)
git -c user.name=ReleaseCheck -c user.email=release-check@example.invalid tag -a "$BUFFERA_TAG" -m fixture

expect_failure() {
  local label="$1"
  if zsh scripts/create-release.sh --disable-sandbox > "$CHECK_ROOT/result.log" 2>&1; then
    print -u2 "FAIL: $label was accepted"
    exit 1
  fi
  [[ ! -e "$RELEASE_CHECK_CALL" ]]
  print "PASS: $label prevents upload"
}
for RELEASE_CHECK_MODE in wrong-remote api-error exists; do
  export RELEASE_CHECK_MODE
  expect_failure "$RELEASE_CHECK_MODE"
done
unset RELEASE_CHECK_MODE
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
[[ "$(cat "dist/releases/$BUFFERA_TAG/RELEASE_NOTES.md")" == 'Fixture release notes' ]]
/usr/bin/grep -Fxq -- --draft "$RELEASE_CHECK_CALL"
/usr/bin/grep -Fxq -- --verify-tag "$RELEASE_CHECK_CALL"
/usr/bin/grep -Fxq -- "$BUFFERA_TAG" "$RELEASE_CHECK_CALL"
(cd "dist/releases/$BUFFERA_TAG" && shasum -a 256 -c SHA256SUMS.txt)
print 'PASS: exact tagged sources, isolated build, artifacts and draft-only GitHub call'
