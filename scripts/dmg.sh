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
# build/dmg-venv on first use. To redraw the picture, run
# node scripts/dmg/dmg-background.mjs.
#
# For a download people can open without warnings, sign and notarize it
# (one-time setup in docs/RELEASING.md):
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=kiri-notary scripts/dmg.sh --build
#
# SIGN_IDENTITY signs the app (hardened runtime, secure timestamp) and the
# disk image. Notarization then needs one of:
#   NOTARY_PROFILE                          a profile saved in the keychain by
#                                           xcrun notarytool store-credentials
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER an App Store Connect API key (.p8)
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD  an app-specific password
# The app and the disk image are each notarized and stapled, so both open
# offline, then Gatekeeper is asked to accept them. Without SIGN_IDENTITY the
# app stays ad-hoc signed and none of this runs: fine for your own Mac only.
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/Kiri.app"
DMGBUILD_VERSION=1.6.7
# Finder's title bar, added to the window so the content is exactly the
# picture's 660 x 392 points.
WINDOW_CHROME=${WINDOW_CHROME:-32}
SIGN_IDENTITY=${SIGN_IDENTITY:--}

BUILD=0
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        --open) OPEN=1 ;;
        *) echo "usage: scripts/dmg.sh [--build] [--open]" >&2; exit 2 ;;
    esac
done

# --- Signing and notarization settings, checked before anything slow runs.

NOTARY=
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY=profile
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ]; then
    NOTARY=key
    [ -f "$NOTARY_KEY" ] || { echo "NOTARY_KEY: no file at $NOTARY_KEY" >&2; exit 1; }
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    NOTARY=password
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    if [ -n "$NOTARY" ]; then
        echo "Notarization needs a Developer ID: set SIGN_IDENTITY too (security find-identity -v -p codesigning lists yours)." >&2
        exit 1
    fi
else
    # The full name, its hash or a part of the name, as codesign takes it.
    if ! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
        echo "No signing identity \"$SIGN_IDENTITY\" in the keychain. Yours:" >&2
        security find-identity -v -p codesigning >&2
        exit 1
    fi
    case "$SIGN_IDENTITY" in
        *"Developer ID Application"*) ;;
        *) echo "Note: \"$SIGN_IDENTITY\" is not a Developer ID Application identity; Gatekeeper only accepts those for downloads." >&2 ;;
    esac
fi

# notarize <file>: submits, waits, and fails with Apple's log if it's refused.
notarize() {
    file=$1
    out="$WORK/notary-$(basename "$file").plist"
    set -- xcrun notarytool submit "$file" --wait --output-format plist
    case "$NOTARY" in
        profile) set -- "$@" --keychain-profile "$NOTARY_PROFILE" ;;
        key) set -- "$@" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" ${NOTARY_ISSUER:+--issuer "$NOTARY_ISSUER"} ;;
        password) set -- "$@" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" ;;
    esac
    echo "==> Notarizing $(basename "$file") (usually a few minutes)"
    "$@" >"$out" || true
    status=$(/usr/libexec/PlistBuddy -c "Print :status" "$out" 2>/dev/null || echo "")
    id=$(/usr/libexec/PlistBuddy -c "Print :id" "$out" 2>/dev/null || echo "")
    if [ "$status" != "Accepted" ]; then
        echo "Notarization of $(basename "$file") ended with status \"${status:-no answer}\"." >&2
        cat "$out" >&2
        if [ -n "$id" ]; then
            shift 7 # keep only the credentials
            echo "Apple's log:" >&2
            xcrun notarytool log "$id" "$@" >&2 || true
        fi
        exit 1
    fi
    echo "    accepted ($id)"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- The app.

if [ "$BUILD" = 1 ]; then
    SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build.sh
fi
[ -d "$APP" ] || { echo "No $APP: run scripts/build.sh first (or scripts/dmg.sh --build)" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$ROOT/build/Kiri-$VERSION.dmg"

if [ "$SIGN_IDENTITY" != "-" ]; then
    # Signed again even after build.sh, so an app built earlier (ad hoc) gets
    # the identity too. Hardened runtime and a secure timestamp are what
    # notarization asks for; Kiri needs no entitlements (it isn't sandboxed).
    echo "==> Signing Kiri.app with $SIGN_IDENTITY"
    scripts/codesign-app.sh "$APP" "$SIGN_IDENTITY"
    if [ -n "$NOTARY" ]; then
        ditto -c -k --keepParent "$APP" "$WORK/Kiri.zip"
        notarize "$WORK/Kiri.zip"
        xcrun stapler staple -q "$APP"
    fi
fi

# --- dmgbuild in a venv of its own, pinned.

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

# --- The disk image.

# The mounted disk's icon: Kiri's own.
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
hdiutil verify -quiet "$DMG"

if [ "$SIGN_IDENTITY" != "-" ]; then
    echo "==> Signing $(basename "$DMG")"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"
    if [ -n "$NOTARY" ]; then
        notarize "$DMG"
        xcrun stapler staple -q "$DMG"
        xcrun stapler validate -q "$DMG"
        echo "==> Asking Gatekeeper"
        spctl --assess --type open --context context:primary-signature -v "$DMG"
        spctl --assess --type execute -v "$APP"
    else
        echo "Signed but not notarized: set NOTARY_PROFILE (see docs/RELEASING.md) before publishing it." >&2
    fi
fi

echo "Packed $DMG ($(du -h "$DMG" | cut -f1))"
[ "$OPEN" = 1 ] && open "$DMG"
exit 0
