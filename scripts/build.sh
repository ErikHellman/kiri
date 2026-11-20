#!/bin/sh
# Builds a release Kiri.app into build/Kiri.app, ad-hoc signed.
#
#   scripts/build.sh            build
#   scripts/build.sh --install  build and copy to /Applications
#
# Needs Xcode 26+ and XcodeGen (brew install xcodegen). To sign with your
# own identity, set SIGN_IDENTITY (default "-", ad hoc).
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SIGN_IDENTITY=${SIGN_IDENTITY:--}
DERIVED="$ROOT/build/DerivedData"
APP="$ROOT/build/Kiri.app"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

(cd App && xcodegen --quiet)
xcodebuild build -project App/Kiri.xcodeproj -scheme Kiri -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO -quiet

rm -rf "$APP"
cp -R "$DERIVED/Build/Products/Release/Kiri.app" "$APP"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
    osascript -e 'quit app "Kiri"' >/dev/null 2>&1 || true
    rm -rf /Applications/Kiri.app
    cp -R "$APP" /Applications/Kiri.app
    echo "Installed /Applications/Kiri.app"
fi
