#!/bin/zsh
# Shared by app/runtime builds and release preparation. Source from the repo root.
# Read data, never shell code, from the ignored machine-local configuration.
if [[ -z "${BUFFERA_SIGNING_IDENTITY+x}" ]]; then
  if [[ -f output/developer-id/signing-identity.txt ]]; then
    BUFFERA_SIGNING_IDENTITY=$(< output/developer-id/signing-identity.txt)
  else
    BUFFERA_SIGNING_IDENTITY=-
  fi
fi
if [[ "$BUFFERA_SIGNING_IDENTITY" != - ]]; then
  if [[ ${#BUFFERA_SIGNING_IDENTITY} != 40 || "$BUFFERA_SIGNING_IDENTITY" == *[^0-9A-Fa-f]* ]]; then
    print -u2 'BUFFERA_SIGNING_IDENTITY must be a Developer ID Application certificate SHA-1 hash, or - for ad-hoc.'
    return 1
  fi
  BUFFERA_SIGNING_IDENTITY="${(U)BUFFERA_SIGNING_IDENTITY}"
  BUFFERA_VALID_IDENTITIES=$(security find-identity -v -p codesigning) || return 1
  if ! print -r -- "$BUFFERA_VALID_IDENTITIES" | /usr/bin/grep -Eq "^[[:space:]]*[0-9]+\) $BUFFERA_SIGNING_IDENTITY \"Developer ID Application: "; then
    print -u2 "Developer ID Application identity $BUFFERA_SIGNING_IDENTITY is unavailable or invalid. Check the certificate and private key in Keychain."
    return 1
  fi
  unset BUFFERA_VALID_IDENTITIES
fi
# Runtime preparation and a release's isolated checkout must use the same identity.
export BUFFERA_SIGNING_IDENTITY

buffera_sign_code() {
  local target="$1"
  local kind="$2"
  local -a signing_options=(--force --sign "$BUFFERA_SIGNING_IDENTITY")
  if [[ "$BUFFERA_SIGNING_IDENTITY" != - ]]; then
    signing_options+=(--timestamp)
    if [[ "$kind" == executable ]]; then
      signing_options+=(--options runtime)
    fi
  fi
  if [[ -n "${3:-}" ]]; then
    signing_options+=(--identifier "$3")
  fi
  codesign "${signing_options[@]}" "$target"
}
