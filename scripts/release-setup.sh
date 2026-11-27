#!/bin/sh
# One-time setup for releasing Kiri from GitHub (.github/workflows/release.yml).
# Run it on your Mac, in the repo; docs/RELEASING.md says what each part is.
#
#   scripts/release-setup.sh
#
# It, in turn:
#   1. makes the kiri repo public, if it isn't yet: Sparkle downloads the
#      updates from its releases without signing in;
#   2. makes the `release` and `symbols` environments, if they aren't there
#      yet: the secrets are theirs, only v* tags may use them, and each
#      release waits at `release` for your approval;
#   3. makes Sparkle's update signing key (kept in your login keychain),
#      writes its public half into App/project.yml, and stores the private
#      half as the SPARKLE_PRIVATE_KEY secret;
#   4. stores your Developer ID (.p12) and its password;
#   5. stores the App Store Connect API key (.p8), its key ID and issuer ID;
#   6. stores the Vaka token, for the debug symbols (optional), in the
#      `symbols` environment: it is kept off the machine that signs;
#   7. deletes repository-level copies of these secrets, from before they
#      were the environment's: a workflow on any branch could read those.
# Each step asks first, so it can be run again for one of them. Nothing
# secret is written into the repo or left on disk: secrets go straight to
# `gh secret set`. Needs the GitHub CLI (brew install gh, gh auth login).
set -eu

cd "$(dirname "$0")/.."
ROOT=$(pwd)
REPO=${REPO:-ErikHellman/kiri}
# The environments of the sign and symbols jobs (.github/workflows/release.yml).
ENVIRONMENT=${ENVIRONMENT:-release}
SYMBOLS_ENVIRONMENT=${SYMBOLS_ENVIRONMENT:-symbols}
# As in .github/workflows/release.yml.
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

command -v gh >/dev/null || { echo "Needs the GitHub CLI: brew install gh && gh auth login" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }

ask() { # ask "Question?": yes or no
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}
prompt() { # prompt "Label" -> the answer on stdout
    printf '%s: ' "$1" >&2
    read -r value
    printf '%s' "$value"
}
secret_prompt() { # like prompt, without echoing what is typed
    printf '%s: ' "$1" >&2
    stty -echo
    read -r value
    stty echo
    echo >&2
    printf '%s' "$value"
}
set_secret() { # set_secret NAME [environment] < value, as a secret of the environment
    gh secret set "$1" --repo "$REPO" --env "${2:-$ENVIRONMENT}"
}
make_environment() { # make_environment NAME REVIEWERS-JSON: only v* tags may use it
    gh api -X PUT "repos/$REPO/environments/$1" --input - >/dev/null <<EOF
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": $2,
  "deployment_branch_policy": { "protected_branches": false, "custom_branch_policies": true }
}
EOF
    gh api -X POST "repos/$REPO/environments/$1/deployment-branch-policies" \
        -f name='v*' -f type=tag >/dev/null
}

WORK=$(mktemp -d)
trap 'stty echo 2>/dev/null; rm -rf "$WORK"' EXIT

# --- 1. A public repo.

echo
echo "1. $REPO is where the downloads and the update feed live: it must be public"
if [ "$(gh repo view "$REPO" --json visibility --jq .visibility)" = PUBLIC ]; then
    echo "   It is."
elif ask "   Make $REPO public now? Its code and history become visible to everyone."; then
    gh repo edit "$REPO" --visibility public --accept-visibility-change-consequences
fi

# --- 2. The environments.

echo
echo "2. The $ENVIRONMENT environment holds the signing secrets: only v* tags may use it,"
echo "   and each release waits there for your approval"
if gh api "repos/$REPO/environments/$ENVIRONMENT" >/dev/null 2>&1; then
    echo "   It is there: https://github.com/$REPO/settings/environments"
elif ask "   Make it, with you as its reviewer?"; then
    make_environment "$ENVIRONMENT" "[{ \"type\": \"User\", \"id\": $(gh api user --jq .id) }]"
    echo "   Made. Untick \"Allow administrators to bypass configured protection rules\" there:"
    echo "   https://github.com/$REPO/settings/environments"
else
    echo "   Without it there is nowhere to store the secrets." >&2
    exit 1
fi
echo "   The $SYMBOLS_ENVIRONMENT environment holds the Vaka token: only v* tags may use it, nobody approves"
if gh api "repos/$REPO/environments/$SYMBOLS_ENVIRONMENT" >/dev/null 2>&1; then
    echo "   It is there."
elif ask "   Make it?"; then
    make_environment "$SYMBOLS_ENVIRONMENT" "[]"
    echo "   Made."
fi

# --- 3. Sparkle's EdDSA key.

echo
echo "3. The update signing key (Sparkle EdDSA)"
if ask "   Make it (or reuse the one in your keychain), put the public key in App/project.yml and store the private key as SPARKLE_PRIVATE_KEY?"; then
    SPARKLE="$ROOT/build/sparkle-$SPARKLE_VERSION"
    if [ ! -x "$SPARKLE/bin/generate_keys" ]; then
        echo "   Downloading Sparkle $SPARKLE_VERSION's tools"
        mkdir -p "$SPARKLE"
        curl -fsSL -o "$WORK/Sparkle.tar.xz" \
            "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
        echo "$SPARKLE_SHA256  $WORK/Sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
        tar -xf "$WORK/Sparkle.tar.xz" -C "$SPARKLE"
    fi
    # Makes a key the first time (macOS may ask to allow keychain access);
    # after that it finds the same one.
    "$SPARKLE/bin/generate_keys" >/dev/null
    PUBLIC=$("$SPARKLE/bin/generate_keys" -p | tr -d '[:space:]')
    case "$PUBLIC" in
        ????????????????????????????????????????????) ;; # 44 characters of base64
        *) echo "   generate_keys -p printed \"$PUBLIC\", not a public key" >&2; exit 1 ;;
    esac
    sed -i '' "s|^\( *KIRI_SPARKLE_PUBLIC_KEY:\).*|\1 \"$PUBLIC\"|" App/project.yml
    grep -q "KIRI_SPARKLE_PUBLIC_KEY: \"$PUBLIC\"" App/project.yml
    echo "   Public key $PUBLIC is in App/project.yml: commit and push that."
    "$SPARKLE/bin/generate_keys" -x "$WORK/sparkle-private-key" >/dev/null
    set_secret SPARKLE_PRIVATE_KEY < "$WORK/sparkle-private-key"
    rm -f "$WORK/sparkle-private-key"
    echo "   Keep the private key safe: it is \"Private key for signing Sparkle updates\" in your login keychain."
    echo "   Lose it and the copies already out there can't update any more."
fi

# --- 4. The Developer ID.

echo
echo "4. The Developer ID Application certificate"
echo "   Export it first: Keychain Access > login > My Certificates >"
echo "   \"Developer ID Application: ...\" > right-click > Export... > .p12, with a password."
if ask "   Store a .p12 as DEVELOPER_ID_P12 (and its password)?"; then
    P12=$(prompt "   Path to the .p12")
    P12=$(eval echo "$P12") # ~ and quotes from a drag into Terminal
    [ -f "$P12" ] || { echo "   No file at $P12" >&2; exit 1; }
    PASSWORD=$(secret_prompt "   Its password")
    # Checked before it is stored, the way the release job will open it:
    # imported into a keychain of its own, then that keychain deleted.
    CHECK="$WORK/check.keychain-db"
    security create-keychain -p check "$CHECK"
    if ! security import "$P12" -k "$CHECK" -P "$PASSWORD" -f pkcs12 >/dev/null 2>&1; then
        security delete-keychain "$CHECK"
        echo "   That password doesn't open $P12" >&2
        exit 1
    fi
    if ! security find-identity -p codesigning "$CHECK" | grep -q "Developer ID Application"; then
        security delete-keychain "$CHECK"
        echo "   $P12 holds no Developer ID Application identity (with its private key)" >&2
        exit 1
    fi
    security delete-keychain "$CHECK"
    base64 -i "$P12" | tr -d '\n' | set_secret DEVELOPER_ID_P12
    printf '%s' "$PASSWORD" | set_secret DEVELOPER_ID_P12_PASSWORD
    echo "   Stored. You can delete the .p12 file now."
fi

# --- 5. The App Store Connect API key.

echo
echo "5. The App Store Connect API key, for notarization"
echo "   Make one: https://appstoreconnect.apple.com/access/integrations/api > Team Keys > +,"
echo "   access Developer. Download the .p8 (it can only be downloaded once)."
if ask "   Store a .p8 as NOTARY_KEY_P8 (and its key ID and issuer ID)?"; then
    P8=$(prompt "   Path to AuthKey_XXXXXXXXXX.p8")
    P8=$(eval echo "$P8")
    [ -f "$P8" ] || { echo "   No file at $P8" >&2; exit 1; }
    grep -q "BEGIN PRIVATE KEY" "$P8" || { echo "   $P8 isn't a .p8 key" >&2; exit 1; }
    GUESS=$(basename "$P8" .p8 | sed -n 's/^AuthKey_//p')
    KEY_ID=$(prompt "   Key ID${GUESS:+ (Enter for $GUESS)}")
    KEY_ID=${KEY_ID:-$GUESS}
    ISSUER=$(prompt "   Issuer ID (above the list of keys)")
    [ -n "$KEY_ID" ] && [ -n "$ISSUER" ] || { echo "   Both IDs are needed" >&2; exit 1; }
    set_secret NOTARY_KEY_P8 < "$P8"
    printf '%s' "$KEY_ID" | set_secret NOTARY_KEY_ID
    printf '%s' "$ISSUER" | set_secret NOTARY_ISSUER_ID
    echo "   Stored. Keep the .p8 somewhere safe or delete it; a new key can be made any time."
fi

# --- 6. The Vaka token.

echo
echo "6. The Vaka API token, for the debug symbols of crash reports (optional)"
echo "   Make one in the Vaka admin UI, https://vaka.fly.dev/ui, with write access to kiri-macos."
if ask "   Store a token as VAKA_TOKEN?"; then
    TOKEN=$(secret_prompt "   The token")
    [ -n "$TOKEN" ] || { echo "   No token given" >&2; exit 1; }
    printf '%s' "$TOKEN" | set_secret VAKA_TOKEN "$SYMBOLS_ENVIRONMENT"
    echo "   Stored."
fi

# --- 7. Repository-level copies, from before the environment.

echo
echo "7. Repository-level copies of the secrets"
NAMES="DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID SPARKLE_PRIVATE_KEY VAKA_TOKEN"
AT_REPO=$(gh secret list --repo "$REPO" --json name --jq '.[].name')
IN_ENVIRONMENT=$(
    gh secret list --repo "$REPO" --env "$ENVIRONMENT" --json name --jq '.[].name' | grep -vx VAKA_TOKEN || true
    gh secret list --repo "$REPO" --env "$SYMBOLS_ENVIRONMENT" --json name --jq '.[].name' 2>/dev/null | grep -x VAKA_TOKEN || true
)
has() { # has "$LIST" NAME
    printf '%s\n' "$1" | grep -qx "$2"
}
OLD=
for name in $NAMES; do
    has "$AT_REPO" "$name" && OLD="$OLD $name"
done
if [ -z "$OLD" ]; then
    echo "   None."
else
    echo "   A workflow on any branch can read these:$OLD"
    echo "   Delete them once a release has gone through with the environment's."
    if ask "   Delete now the ones the environments have too?"; then
        for name in $OLD; do
            if has "$IN_ENVIRONMENT" "$name"; then
                gh secret delete "$name" --repo "$REPO"
            else
                echo "   Kept $name: its environment doesn't have it yet."
            fi
        done
    fi
fi

echo
echo "The secrets the $ENVIRONMENT environment of $REPO has now:"
gh secret list --repo "$REPO" --env "$ENVIRONMENT"
echo "And the $SYMBOLS_ENVIRONMENT environment:"
gh secret list --repo "$REPO" --env "$SYMBOLS_ENVIRONMENT" 2>/dev/null || echo "(no such environment)"
