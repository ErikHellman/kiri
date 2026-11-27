#!/bin/sh
# Builds a release Kiri.app into build/Kiri.app, ad-hoc signed.
#
#   scripts/build.sh            build
#   scripts/build.sh --install  build and copy to /Applications
#
# Needs Xcode 26+ and XcodeGen (brew install xcodegen). To sign with your
# own identity, set SIGN_IDENTITY (default "-", ad hoc). Builds for this
# Mac's architecture; ARCH="arm64 x86_64" builds a universal app.
# KIRI_VERSION and KIRI_BUILD, if set, replace App/project.yml's version
# (CFBundleShortVersionString) and build number (CFBundleVersion), as the
# release workflow does. KIRI_WARNINGS_AS_ERRORS=YES fails the build on a
# warning in Kiri's own code, as CI does.
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SIGN_IDENTITY=${SIGN_IDENTITY:--}
DERIVED="$ROOT/build/DerivedData"
ARCH=${ARCH:-$(uname -m)}
APP="$ROOT/build/Kiri.app"
PROJECT=App/Kiri.xcodeproj
VERSION_SETTINGS=
[ -n "${KIRI_VERSION:-}" ] && VERSION_SETTINGS="MARKETING_VERSION=$KIRI_VERSION"
[ -n "${KIRI_BUILD:-}" ] && VERSION_SETTINGS="$VERSION_SETTINGS CURRENT_PROJECT_VERSION=$KIRI_BUILD"

command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }

# Tracked files that are gone from the working tree (say, a folder moved by
# accident in Xcode or Finder) make xcodebuild fail with a bare "No such file
# or directory". Name them up front. Only a warning: deleting a file is also
# a normal step in a change.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    missing=$(git ls-files --deleted)
    if [ -n "$missing" ]; then
        echo "warning: these tracked files are missing from the working tree:" >&2
        echo "$missing" | sed 's/^/    /' >&2
        echo "If that isn't intended, bring them back with: git restore <path>" >&2
    fi
fi

# xcodebuild runs git (package fetches) and its build service in process
# groups of their own, so Ctrl+C in the terminal never reaches them: git keeps
# downloading and xcodebuild keeps waiting. So xcodebuild runs as a job in its
# own process group (set -m), and on Ctrl+C the script stops every group under
# it, then xcodebuild itself.
XCODEBUILD_PID=
descendants() {
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        descendants "$child"
    done
}
stop_xcodebuild() {
    trap - INT TERM HUP
    set +e # clean up even if a step fails (say, the terminal is gone)
    echo >&2
    echo "Interrupted, stopping xcodebuild..." >&2
    if [ -n "$XCODEBUILD_PID" ]; then
        exec 2>/dev/null # no "Terminated" job notices from the shell
        # Note the groups under xcodebuild before it exits and they're orphaned.
        own_group=$(ps -o pgid= -p $$ | tr -d ' ')
        groups=
        for pid in $(descendants "$XCODEBUILD_PID"); do
            group=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || continue
            [ -n "$group" ] && [ "$group" != "$own_group" ] && groups="$groups $group"
        done
        # Let xcodebuild cancel the build itself, then stop whatever is left.
        kill -TERM -- "-$XCODEBUILD_PID" 2>/dev/null || kill -TERM "$XCODEBUILD_PID" 2>/dev/null
        tries=0
        while kill -0 "$XCODEBUILD_PID" 2>/dev/null && [ $tries -lt 20 ]; do
            sleep 0.25
            tries=$((tries + 1))
        done
        for group in $groups; do
            kill -TERM -- "-$group" 2>/dev/null
        done
        kill -KILL -- "-$XCODEBUILD_PID" 2>/dev/null
        wait "$XCODEBUILD_PID" 2>/dev/null || true
    fi
    exit 130
}
run_xcodebuild() {
    trap stop_xcodebuild INT TERM HUP
    set -m
    xcodebuild "$@" </dev/null &
    XCODEBUILD_PID=$!
    set +m
    status=0
    wait "$XCODEBUILD_PID" || status=$?
    trap - INT TERM HUP
    XCODEBUILD_PID=
    return "$status"
}

(cd App && xcodegen --quiet)

# Fetching the Tree-sitter grammars is the slow part of a first build (about
# 1.4 GB of git history), so it runs as its own step with progress shown.
if [ -d "$DERIVED/SourcePackages/checkouts" ]; then
    echo "==> Checking Swift packages"
    run_xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme Kiri -derivedDataPath "$DERIVED" -quiet
else
    echo "==> Fetching Swift packages (the first build downloads about 1.4 GB)"
    run_xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme Kiri -derivedDataPath "$DERIVED"
fi

echo "==> Building Kiri (Release, $ARCH)"
run_xcodebuild build -project "$PROJECT" -scheme Kiri -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" -skipPackageUpdates \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO $VERSION_SETTINGS \
    ${KIRI_WARNINGS_AS_ERRORS:+KIRI_WARNINGS_AS_ERRORS=$KIRI_WARNINGS_AS_ERRORS} -quiet

rm -rf "$APP"
cp -R "$DERIVED/Build/Products/Release/Kiri.app" "$APP"
# Inside out, Sparkle's helpers first; a real identity also gets a secure
# timestamp, which notarization needs.
scripts/codesign-app.sh "$APP" "$SIGN_IDENTITY"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
    osascript -e 'quit app "Kiri"' >/dev/null 2>&1 || true
    rm -rf /Applications/Kiri.app
    cp -R "$APP" /Applications/Kiri.app
    echo "Installed /Applications/Kiri.app"
fi
