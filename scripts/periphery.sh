#!/bin/sh
# Finds unused code with Periphery (.periphery.yml).
#
#   scripts/periphery.sh            scan and list what is unused
#   scripts/periphery.sh --strict   the same, and exit 1 if anything is
#
# Needs Xcode, XcodeGen and Periphery (brew install xcodegen periphery).
# It builds the app and KiriKit's tests (a minute or two) in its own
# project, App/KiriPeriphery.xcodeproj, which is generated and not
# checked in. Before deleting anything it lists, grep for it: what is
# reached only by name at run time shows up here too (CLAUDE.md).
set -eu

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
command -v periphery >/dev/null || { echo "periphery not found: brew install periphery" >&2; exit 1; }

(cd App && xcodegen --quiet --spec periphery.yml)
exec periphery scan --config .periphery.yml --disable-update-check "$@"
