#!/bin/sh
# Signs Kiri.app from the inside out: Sparkle's helpers, then the frameworks,
# then the app, each with the hardened runtime. Used by scripts/build.sh and
# scripts/dmg.sh.
#
#   scripts/codesign-app.sh <Kiri.app> <identity>
#
# Identity "-" signs ad hoc (no timestamp); a real one, such as a Developer
# ID, also gets the secure timestamp notarization asks for.
#
# Not `codesign --deep`: it signs nested code in no particular order and
# drops the entitlements of Sparkle's Downloader service, which is what
# Sparkle's documentation warns about.
set -eu

APP=$1
IDENTITY=$2
TIMESTAMP=--timestamp=none
[ "$IDENTITY" = "-" ] || TIMESTAMP=--timestamp

sign() {
    codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" "$@"
}

FRAMEWORKS="$APP/Contents/Frameworks"
SPARKLE="$FRAMEWORKS/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    B="$SPARKLE/Versions/B"
    [ -d "$B/XPCServices/Installer.xpc" ] && sign "$B/XPCServices/Installer.xpc"
    [ -d "$B/XPCServices/Downloader.xpc" ] && sign --preserve-metadata=entitlements "$B/XPCServices/Downloader.xpc"
    sign "$B/Autoupdate"
    sign "$B/Updater.app"
    sign "$SPARKLE"
fi

# Any other embedded framework or library.
if [ -d "$FRAMEWORKS" ]; then
    for item in "$FRAMEWORKS"/*; do
        [ -e "$item" ] || continue
        [ "$item" = "$SPARKLE" ] && continue
        sign "$item"
    done
fi

sign "$APP"
codesign --verify --deep --strict "$APP"
