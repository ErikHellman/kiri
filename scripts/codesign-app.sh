#!/bin/sh
# Signs Kiri.app from the inside out: Sparkle's helpers, then the frameworks,
# then the app. Used by scripts/build.sh and scripts/dmg.sh.
#
#   scripts/codesign-app.sh <Kiri.app> <identity>
#
# Identity "-" signs ad hoc, for local builds. A real one, such as a Developer
# ID, also gets the hardened runtime and the secure timestamp that
# notarization asks for. Ad hoc code goes without the hardened runtime: its
# library validation rejects an ad hoc Sparkle.framework (no Team ID to match),
# so the app would stop at launch with nothing on screen.
#
# Not `codesign --deep`: it signs nested code in no particular order and
# drops the entitlements of Sparkle's Downloader service, which is what
# Sparkle's documentation warns about.
set -eu

APP=$1
IDENTITY=$2
TIMESTAMP=--timestamp=none
RUNTIME=
if [ "$IDENTITY" != "-" ]; then
    TIMESTAMP=--timestamp
    RUNTIME="--options runtime"
fi

sign() {
    codesign --force $RUNTIME $TIMESTAMP --sign "$IDENTITY" "$@"
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
