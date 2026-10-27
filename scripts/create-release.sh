#!/bin/zsh
# Build the exact tagged sources and upload a draft GitHub Release.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help ]]; then
  print 'Usage: zsh scripts/create-release.sh [--disable-sandbox]'
  print 'Requires a committed version, release notes and a matching tag already pushed to GitHub.'
  print 'Builds tagged sources, saves artifacts in dist/releases/vX.Y.Z and creates a draft release.'
  exit 0
fi
if (( $# > 1 )) || [[ $# == 1 && "$1" != --disable-sandbox ]]; then
  print -u2 'Only --disable-sandbox is accepted; use --help for details.'
  exit 1
fi
source scripts/version.sh
REPO=dqunbp/buffera
NOTES="docs/releases/$BUFFERA_VERSION.md"
OUTPUT="$PWD/dist/releases/$BUFFERA_TAG"

if [[ "$(uname -m)" != arm64 ]]; then
  print -u2 'Releases require an Apple Silicon Mac.'
  exit 1
fi
git ls-files --error-unmatch "$BUFFERA_VERSION_SOURCE" "$NOTES" >/dev/null
if ! git diff --quiet HEAD --; then
  print -u2 'Commit tracked changes before releasing. The release is built from the tag, not the working directory.'
  exit 1
fi
COMMIT=$(git rev-parse HEAD)
if [[ "$(git rev-parse --verify "refs/tags/$BUFFERA_TAG^{commit}")" != "$COMMIT" ]]; then
  print -u2 "Tag $BUFFERA_TAG must point to HEAD."
  exit 1
fi
REMOTE_REFS=$(git ls-remote "https://github.com/$REPO.git" "refs/tags/$BUFFERA_TAG" "refs/tags/$BUFFERA_TAG^{}")
REMOTE_COMMIT=$(print -r -- "$REMOTE_REFS" | awk '
  $2 ~ /\^\{\}$/ { peeled = $1 }
  $2 !~ /\^\{\}$/ { direct = $1 }
  END { print peeled ? peeled : direct }')
if [[ "$REMOTE_COMMIT" != "$COMMIT" ]]; then
  print -u2 "Push $BUFFERA_TAG to $REPO first; its remote commit must match HEAD."
  exit 1
fi
# A failed API request must stop the release, not be mistaken for a missing release.
EXISTING_TAGS=$(gh api --paginate "repos/$REPO/releases" --jq '.[].tag_name')
if print -r -- "$EXISTING_TAGS" | /usr/bin/grep -Fxq "$BUFFERA_TAG"; then
  print -u2 "Release $BUFFERA_TAG already exists. Inspect it with: gh release view $BUFFERA_TAG --repo $REPO"
  exit 1
fi

RELEASE_SOURCE=$(mktemp -d "${TMPDIR:-/tmp}/buffera-release-source.XXXXXX")
trap 'rm -rf "$RELEASE_SOURCE"' EXIT
git archive "$COMMIT" | tar -xf - -C "$RELEASE_SOURCE"
(
  cd "$RELEASE_SOURCE"
  # Isolate the build from local files and any caller-provided scratch path.
  unset BUFFERA_BUILD_PATH
  zsh scripts/build-app.sh "$@"
  zsh scripts/package-release.sh
)
mkdir -p "$OUTPUT"
cp "$RELEASE_SOURCE/dist/Buffera-macOS-arm64.dmg" "$OUTPUT/"
cp "$RELEASE_SOURCE/dist/SHA256SUMS.txt" "$OUTPUT/"
cp "$RELEASE_SOURCE/$NOTES" "$OUTPUT/RELEASE_NOTES.md"
print "Verified release artifacts: $OUTPUT"
gh release create "$BUFFERA_TAG" \
  "$OUTPUT/Buffera-macOS-arm64.dmg" "$OUTPUT/SHA256SUMS.txt" \
  --repo "$REPO" --verify-tag --draft \
  --title "Buffera $BUFFERA_VERSION" --notes-file "$OUTPUT/RELEASE_NOTES.md"
print 'Draft created. Review its notes and both assets on GitHub before publishing.'
