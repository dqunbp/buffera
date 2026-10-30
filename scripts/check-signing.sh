#!/bin/zsh
# Test identity selection and fail-closed signing without accessing real keys.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/buffera-signing-check.XXXXXX")
trap 'rm -rf "$CHECK_ROOT"' EXIT
mkdir -p "$CHECK_ROOT/bin" "$CHECK_ROOT/repo/scripts" "$CHECK_ROOT/repo/output/developer-id"
cp scripts/signing.sh "$CHECK_ROOT/repo/scripts/"
export SIGNING_CHECK_HASH=0123456789ABCDEF0123456789ABCDEF01234567
export SIGNING_CHECK_LOG="$CHECK_ROOT/codesign.log"
cat > "$CHECK_ROOT/bin/security" <<'SH'
#!/bin/zsh
[[ "$*" == 'find-identity -v -p codesigning' ]] || exit 9
case "${SIGNING_CHECK_MODE:-}" in
  missing) print '     0 valid identities found' ;;
  wrong-type) print "  1) $SIGNING_CHECK_HASH \"Apple Development: Fixture\"" ;;
  security-error) exit 8 ;;
  *) print "  1) $SIGNING_CHECK_HASH \"Developer ID Application: Fixture (TESTTEAM)\"" ;;
esac
SH
cat > "$CHECK_ROOT/bin/codesign" <<'SH'
#!/bin/zsh
print -rl -- "$@" > "$SIGNING_CHECK_LOG"
[[ "${SIGNING_CHECK_MODE:-}" != signing-error ]]
SH
chmod +x "$CHECK_ROOT/bin/"*
export PATH="$CHECK_ROOT/bin:$PATH"
cd "$CHECK_ROOT/repo"
unset BUFFERA_SIGNING_IDENTITY
zsh -ec 'source scripts/signing.sh; [[ "$BUFFERA_SIGNING_IDENTITY" == - ]]; buffera_sign_code "app with spaces" executable'
! /usr/bin/grep -Fxq -- --timestamp "$SIGNING_CHECK_LOG"
! /usr/bin/grep -Fxq -- runtime "$SIGNING_CHECK_LOG"
/usr/bin/grep -Fxq -- 'app with spaces' "$SIGNING_CHECK_LOG"
print 'PASS: unconfigured checkout supports ad-hoc signing and paths with spaces'

print -r -- "${(L)SIGNING_CHECK_HASH}" > output/developer-id/signing-identity.txt
zsh -ec 'source scripts/signing.sh; [[ "$BUFFERA_SIGNING_IDENTITY" == "$SIGNING_CHECK_HASH" ]]; buffera_sign_code app executable local.buffera.app.fixture'
for expected in "$SIGNING_CHECK_HASH" --timestamp runtime local.buffera.app.fixture; do
  /usr/bin/grep -Fxq -- "$expected" "$SIGNING_CHECK_LOG"
done
# A child checkout has no local configuration but must retain the identity.
zsh -ec 'source scripts/signing.sh; cd scripts; zsh -ec '\''source signing.sh; [[ "$BUFFERA_SIGNING_IDENTITY" == "$SIGNING_CHECK_HASH" ]]'\'''
zsh -ec 'source scripts/signing.sh; buffera_sign_code library library'
/usr/bin/grep -Fxq -- --timestamp "$SIGNING_CHECK_LOG"
! /usr/bin/grep -Fxq -- runtime "$SIGNING_CHECK_LOG"
BUFFERA_SIGNING_IDENTITY=- zsh -ec 'source scripts/signing.sh; [[ "$BUFFERA_SIGNING_IDENTITY" == - ]]'
print 'PASS: configured Developer ID, timestamp, hardened executables, child inheritance and explicit override'

for SIGNING_CHECK_MODE in missing wrong-type security-error signing-error; do
  export SIGNING_CHECK_MODE
  rm -f "$SIGNING_CHECK_LOG"
  if zsh -ec 'source scripts/signing.sh; buffera_sign_code app executable' > "$CHECK_ROOT/error.log" 2>&1; then
    print -u2 "FAIL: $SIGNING_CHECK_MODE was accepted"
    exit 1
  fi
  if [[ "$SIGNING_CHECK_MODE" != signing-error ]]; then
    [[ ! -e "$SIGNING_CHECK_LOG" ]]
  else
    /usr/bin/grep -Fxq -- "$SIGNING_CHECK_HASH" "$SIGNING_CHECK_LOG"
    ! /usr/bin/grep -Fxq -- - "$SIGNING_CHECK_LOG"
  fi
done
unset SIGNING_CHECK_MODE
for invalid in '' 'Developer ID Application: Fixture' 'not-a-hash'; do
  if BUFFERA_SIGNING_IDENTITY="$invalid" zsh -ec 'source scripts/signing.sh' > "$CHECK_ROOT/error.log" 2>&1; then
    print -u2 'FAIL: malformed identity was accepted'
    exit 1
  fi
done
print 'PASS: missing/invalid identities, Keychain and codesign errors stop without ad-hoc fallback'
