#!/bin/sh
# Checks that a version tag may be released, and says why not when it may
# not. .github/workflows/release.yml runs it first, before anything is
# built or signed; run it yourself before tagging:
#
#   git fetch origin main --tags
#   scripts/check-release-tag.sh v0.6.0 origin/main
#
# The tag is good when:
#   - it is vMAJOR.MINOR.PATCH, three plain numbers (v0.6.0, never v0.6,
#     v0.06.0 or v0.6.0-beta);
#   - the commit (the second argument, HEAD without one) is on the main
#     branch: a release is never built from a branch's commit;
#   - if the tag exists already, it is on that commit;
#   - its version is higher than every other version tag's;
#   - the last version's commit is behind it on main, with at least one
#     commit in between: the build number, the number of commits, which is
#     what Sparkle compares, then only ever grows;
#   - the commit has the version's release notes, docs/release-notes/<version>.md.
#
# RELEASE_BRANCH names the main branch as this checkout has it (default
# origin/main).
set -eu

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 <tag> [commit]" >&2; exit 2; }
TAG=$1
COMMITISH=${2:-HEAD}
MAIN=${RELEASE_BRANCH:-origin/main}
VERSION_PATTERN='v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'

fail() { echo "$TAG can't be released: $*" >&2; exit 1; }

printf '%s\n' "$TAG" | grep -Eqx "$VERSION_PATTERN" \
    || fail "version tags are vMAJOR.MINOR.PATCH, three plain numbers, like v0.6.0"
VERSION=${TAG#v}

COMMIT=$(git rev-parse --verify --quiet "$COMMITISH^{commit}") || fail "there is no commit $COMMITISH"
MAIN_COMMIT=$(git rev-parse --verify --quiet "$MAIN^{commit}") \
    || fail "this checkout has no $MAIN to check the commit against (git fetch origin main)"
git merge-base --is-ancestor "$COMMIT" "$MAIN_COMMIT" \
    || fail "its commit $(git rev-parse --short "$COMMIT") isn't on $MAIN. Tag the merged commit on main"

if TAGGED=$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}"); then
    [ "$TAGGED" = "$COMMIT" ] \
        || fail "the tag is on $(git rev-parse --short "$TAGGED"), not on $(git rev-parse --short "$COMMIT")"
fi

# Whether version $1 is higher than version $2 (each MAJOR.MINOR.PATCH).
higher() {
    a=$1 b=$2
    for _ in 1 2 3; do
        x=${a%%.*} y=${b%%.*}
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
        a=${a#*.} b=${b#*.}
    done
    return 1
}

# The highest of the other version tags: the last version.
LAST=
for other in $(git tag --list 'v*'); do
    [ "$other" != "$TAG" ] || continue
    printf '%s\n' "$other" | grep -Eqx "$VERSION_PATTERN" || continue
    if [ -z "$LAST" ] || higher "${other#v}" "${LAST#v}"; then LAST=$other; fi
done

if [ -n "$LAST" ]; then
    higher "$VERSION" "${LAST#v}" \
        || fail "its version isn't higher than the last one, $LAST. If $LAST was never released, delete that tag first"
    LAST_COMMIT=$(git rev-parse --verify --quiet "refs/tags/$LAST^{commit}")
    [ "$LAST_COMMIT" != "$COMMIT" ] \
        || fail "it is on the same commit as $LAST. A release needs a commit of its own, or its build number is the same and no Mac updates"
    git merge-base --is-ancestor "$LAST_COMMIT" "$COMMIT" \
        || fail "the last version, $LAST, isn't behind its commit on $MAIN, so the build number wouldn't grow"
fi

git cat-file -e "$COMMIT:docs/release-notes/$VERSION.md" 2>/dev/null \
    || fail "its commit has no release notes, docs/release-notes/$VERSION.md (docs/RELEASING.md)"

if [ -n "$LAST" ]; then
    echo "$TAG can be released: on $MAIN, $(git rev-list --count "$LAST_COMMIT..$COMMIT") commits after $LAST."
else
    echo "$TAG can be released: on $MAIN, the first version."
fi
