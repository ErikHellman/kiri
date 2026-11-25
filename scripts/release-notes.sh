#!/bin/sh
# Prints the release notes for one version of Kiri, and fails when there
# are none: every release has notes, written by hand before it is tagged.
#
#   scripts/release-notes.sh 0.3.2        # or v0.3.2
#
# The notes are docs/release-notes/<version>.md on the tagged commit, in
# the Markdown that scripts/appcast.py renders (docs/RELEASING.md, Release
# notes). .github/workflows/release.yml uses this for the GitHub release
# and the Sparkle feed.
set -eu

NOTES_DIR=docs/release-notes

[ $# -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 2; }
VERSION="${1#v}"
FILE="$(cd "$(dirname "$0")/.." && pwd)/$NOTES_DIR/$VERSION.md"

if [ ! -f "$FILE" ]; then
  echo "No release notes for $VERSION: write $NOTES_DIR/$VERSION.md and commit it before tagging (docs/RELEASING.md)." >&2
  exit 1
fi
if ! grep -q '[^[:space:]]' "$FILE"; then
  echo "$NOTES_DIR/$VERSION.md is empty: say what changed since the last release (docs/RELEASING.md)." >&2
  exit 1
fi
cat "$FILE"
