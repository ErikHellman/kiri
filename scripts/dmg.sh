#!/bin/sh
# Packs build/Kiri.app into build/Kiri-<version>.dmg: the Honey window with
# the bee (scripts/dmg/background*.png), Kiri and Applications side by side,
# and Kiri's icon on the mounted disk.
#
#   scripts/dmg.sh            pack build/Kiri.app (run scripts/build.sh first)
#   scripts/dmg.sh --build    build the app, then pack it
#   scripts/dmg.sh --open     pack, then mount it and show the window
#
# Needs Python 3.10+ (python.org, Homebrew or Xcode's). dmgbuild, which writes
# Finder's window layout without scripting Finder, is installed into
# build/dmg-venv on first use. With SIGN_IDENTITY set to a real identity the
# disk image is signed with it too. To redraw the picture, run
# node scripts/dmg/dmg-background.mjs.
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/Kiri.app"
DMGBUILD_VERSION=1.6.7
# Finder's title bar, added to the window so the content is exactly the
# picture's 660 x 392 points.
WINDOW_CHROME=${WINDOW_CHROME:-32}

for arg in "$@"; do
    case "$arg" in
        --build) scripts/build.sh ;;
        --open) ;;
        *) echo "usage: scripts/dmg.sh [--build] [--open]" >&2; exit 2 ;;
    esac
done

[ -d "$APP" ] || { echo "No $APP: run scripts/build.sh first (or scripts/dmg.sh --build)" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$ROOT/build/Kiri-$VERSION.dmg"

# dmgbuild in a venv of its own, pinned.
VENV="$ROOT/build/dmg-venv"
if [ ! -x "$VENV/bin/dmgbuild" ] || ! "$VENV/bin/python" -m pip show dmgbuild 2>/dev/null | grep -q "^Version: $DMGBUILD_VERSION$"; then
    PYTHON=
    for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
            PYTHON=$candidate
            break
        fi
    done
    [ -n "$PYTHON" ] || { echo "dmgbuild needs Python 3.10 or later (brew install python)" >&2; exit 1; }
    echo "==> Installing dmgbuild $DMGBUILD_VERSION into build/dmg-venv"
    rm -rf "$VENV"
    "$PYTHON" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check "dmgbuild==$DMGBUILD_VERSION"
fi

# The mounted disk's icon: Kiri's own.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Kiri.iconset"
mkdir "$ICONSET"
cp App/Kiri/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil --convert icns --output "$WORK/VolumeIcon.icns" "$ICONSET"

# A copy of the image that is still mounted would make hdiutil fail.
if [ -d "/Volumes/Kiri" ]; then
    hdiutil detach "/Volumes/Kiri" -quiet || true
fi

echo "==> Packing $(basename "$DMG")"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg/settings.py \
    -D app="$APP" -D here="$ROOT/scripts/dmg" -D volume_icon="$WORK/VolumeIcon.icns" -D chrome="$WINDOW_CHROME" \
    "Kiri" "$DMG"

SIGN_IDENTITY=${SIGN_IDENTITY:--}
if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
hdiutil verify -quiet "$DMG"
echo "Packed $DMG ($(du -h "$DMG" | cut -f1))"

case " $* " in
    *" --open "*) open "$DMG" ;;
esac
