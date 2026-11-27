#!/bin/sh
# The app's lockfile, App/Package.resolved: the exact commit of every Swift
# package Kiri is built from (Sparkle, Vaka, swift-markdown, Tree-sitter and
# its grammars, and what those need). App/project.yml and
# KiriKit/Package.swift name versions, which are git tags, and a tag can be
# moved; the lockfile names commits, which can't. Every build takes the
# packages at those commits and fails if it would need any other.
#
# Xcode keeps a project's lockfile inside the project, and Kiri.xcodeproj is
# generated (XcodeGen) and not checked in, so the lockfile lives in App/ and
# is put into the project after each generation:
#
#   scripts/packages.sh lock     after xcodegen: the lockfile into the project
#   scripts/packages.sh check    after resolving or building: the project's
#                                is still the lockfile, and KiriKit's own
#                                (KiriKit/Package.resolved, for `swift test`)
#                                names the same commits
#   scripts/packages.sh update   after changing a version in App/project.yml
#                                or KiriKit/Package.swift: resolve again and
#                                take the result as the new lockfile
#
# scripts/build.sh and CI do `lock` and `check` themselves, and build with
# -disableAutomaticPackageResolution. Review what `update` changed before
# committing it: a commit that changed under a version you didn't touch
# means its tag was moved.
set -eu

cd "$(dirname "$0")/.."
LOCK=App/Package.resolved
PROJECT=App/Kiri.xcodeproj
IN_PROJECT="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
KIT=KiriKit/Package.resolved

# compare <lockfile> <other> <same|within>: the pins of the two files (name,
# where from, commit, version; not Xcode's own hash of the project).
#   same:   both have exactly the same packages at the same commits.
#   within: every package of <other> is in <lockfile> at the same commit.
compare() {
    python3 - "$1" "$2" "$3" <<'EOF'
import json, sys

def pins(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    return {
        p["identity"]: (p.get("location", ""), p["state"].get("revision", ""), p["state"].get("version", ""))
        for p in data.get("pins", [])
    }

lock_path, other_path, mode = sys.argv[1:4]
lock, other = pins(lock_path), pins(other_path)
problems = []
for name, (_, revision, version) in sorted(other.items()):
    if name not in lock:
        problems.append(f"{name} {version} is in {other_path} and not in {lock_path}")
    elif lock[name][1] != revision:
        problems.append(f"{name}: {lock_path} has {lock[name][1][:12]} ({lock[name][2]}), {other_path} has {revision[:12]} ({version})")
if mode == "same":
    for name in sorted(set(lock) - set(other)):
        problems.append(f"{name} {lock[name][2]} is in {lock_path} and not in {other_path}")
for problem in problems:
    print(problem, file=sys.stderr)
sys.exit(1 if problems else 0)
EOF
}

need_lock() {
    [ -f "$LOCK" ] || { echo "No $LOCK: scripts/packages.sh update makes it." >&2; exit 1; }
}

case "${1:-}" in
    lock)
        need_lock
        [ -d "$PROJECT" ] || { echo "No $PROJECT: run xcodegen in App first." >&2; exit 1; }
        mkdir -p "$(dirname "$IN_PROJECT")"
        cp "$LOCK" "$IN_PROJECT"
        ;;
    check)
        need_lock
        if [ ! -f "$IN_PROJECT" ]; then
            echo "The project has no lockfile: scripts/packages.sh lock, after xcodegen." >&2
            exit 1
        fi
        if ! compare "$LOCK" "$IN_PROJECT" same; then
            echo "The packages the build resolved aren't the lockfile's ($LOCK)." >&2
            echo "If a version in App/project.yml or KiriKit/Package.swift changed, run scripts/packages.sh update and commit the result." >&2
            exit 1
        fi
        if ! compare "$LOCK" "$KIT" within; then
            echo "$KIT (what swift test uses) and $LOCK name different commits: run scripts/packages.sh update." >&2
            exit 1
        fi
        ;;
    update)
        command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen" >&2; exit 1; }
        (cd App && xcodegen --quiet)
        # KiriKit's own first: `swift package resolve` keeps every pin that
        # still fits Package.swift.
        (cd KiriKit && swift package resolve)
        # The app's: from the lockfile as it is (packages whose version
        # didn't change keep their commit), resolved for what did change.
        # The first time, from KiriKit's: with no lockfile in the project,
        # Xcode writes the app's pins into KiriKit's instead.
        mkdir -p "$(dirname "$IN_PROJECT")"
        if [ -f "$LOCK" ]; then cp "$LOCK" "$IN_PROJECT"; else cp "$KIT" "$IN_PROJECT"; fi
        kit_before=$(shasum "$KIT")
        xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme Kiri \
            -derivedDataPath build/DerivedData
        [ -f "$IN_PROJECT" ] || { echo "xcodebuild wrote no $IN_PROJECT" >&2; exit 1; }
        [ "$(shasum "$KIT")" = "$kit_before" ] || { echo "xcodebuild changed $KIT: look before committing it" >&2; exit 1; }
        cp "$IN_PROJECT" "$LOCK"
        if ! compare "$LOCK" "$KIT" within; then
            echo "$KIT and $LOCK name different commits for the packages above." >&2
            echo "A tag was moved between the two being resolved, or one is stale: look before committing either." >&2
            exit 1
        fi
        echo "Updated $LOCK. Review the change before committing it:"
        git --no-pager diff --stat -- "$LOCK" "$KIT" || true
        ;;
    *)
        echo "usage: scripts/packages.sh lock | check | update" >&2
        exit 2
        ;;
esac
