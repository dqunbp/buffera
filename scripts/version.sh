#!/bin/zsh
# Source from other scripts; do not accept environment overrides for release metadata.
BUFFERA_VERSION_SOURCE="${${(%):-%x}:A:h:h}/Sources/BufferaCore/AppVersion.swift"
BUFFERA_VERSION=$(sed -nE 's/^    public static let version = "([^"]*)"$/\1/p' "$BUFFERA_VERSION_SOURCE")
BUFFERA_BUILD=$(sed -nE 's/^    public static let build = "([^"]*)"$/\1/p' "$BUFFERA_VERSION_SOURCE")
if [[ ! "$BUFFERA_VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] ||
   [[ ! "$BUFFERA_BUILD" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 "Invalid release metadata in $BUFFERA_VERSION_SOURCE (expected X.Y.Z and a positive build number)."
  return 1
fi
BUFFERA_TAG="v$BUFFERA_VERSION"
