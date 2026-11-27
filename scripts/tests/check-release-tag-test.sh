#!/bin/sh
# Tests scripts/check-release-tag.sh in a repository of its own, made in a
# temporary folder. CI runs it (.github/workflows/ci.yml):
#
#   scripts/tests/check-release-tag-test.sh
set -eu

CHECK="$(cd "$(dirname "$0")/.." && pwd)/check-release-tag.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

git init --quiet --initial-branch=main .
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config tag.gpgsign false
export RELEASE_BRANCH=main

commit() {
    echo "$1" >> log
    git add -A
    git commit --quiet -m "$1"
}
notes() {
    mkdir -p docs/release-notes
    echo "- Something new." > "docs/release-notes/$1.md"
}

failures=0
# expect ok|fail <what it shows> <tag> [commit]
expect() {
    want=$1 what=$2
    shift 2
    if "$CHECK" "$@" >out.txt 2>&1; then got=ok; else got=fail; fi
    if [ "$got" = "$want" ]; then
        echo "ok   $what"
    else
        echo "FAIL $what (wanted $want): $(cat out.txt)"
        failures=$((failures + 1))
    fi
    rm -f out.txt
}

notes 0.1.0
commit "first"
expect ok "the first version, with its notes, on main" v0.1.0
git tag v0.1.0
expect ok "a tag that is there already, on that commit" v0.1.0

notes 0.2.0
commit "second"
git tag -a v0.2.0 -m "0.2.0"
expect ok "an annotated tag after the last version" v0.2.0

for bad in 0.3.0 v0.3 v0.3.0.1 v0.03.0 v0.3.0-beta v0.3.x "v0.3.0;true" v; do
    expect fail "a tag that isn't vMAJOR.MINOR.PATCH: $bad" "$bad"
done

expect fail "a version lower than the last one" v0.1.5
expect fail "a version with no notes" v0.3.0

notes 0.1.5
notes 0.2.1
notes 0.10.0
notes 1.0.0
commit "notes"
expect fail "a lower version, even with its notes" v0.1.5
expect ok "a patch after the last version" v0.2.1
expect ok "0.10.0 is higher than 0.2.0 (numbers, not text)" v0.10.0
expect ok "a major version" v1.0.0

expect fail "the commit of the last version again" v0.2.1 v0.2.0
expect fail "a tag that is on another commit" v0.2.0 HEAD

git checkout --quiet -b side
commit "on a branch"
expect fail "a commit that isn't on main" v0.2.1
git tag v0.2.1
expect fail "a tag pushed for a branch's commit" v0.2.1
git tag -d v0.2.1 >/dev/null
git checkout --quiet main

# A higher tag that was never released stands in the way until it is deleted.
git tag v9.0.0
expect fail "a version lower than a stray higher tag" v1.0.0
git tag -d v9.0.0 >/dev/null
git tag not-a-version
git tag v2
expect ok "other tags that aren't versions don't count" v1.0.0

git tag v1.0.0
notes 1.0.1
commit "after 1.0.0"
expect ok "the next patch" v1.0.1
expect fail "a version that jumps back behind the last one" v0.10.0

if [ "$failures" -gt 0 ]; then
    echo "$failures failed" >&2
    exit 1
fi
echo "all passed"
