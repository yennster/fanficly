#!/usr/bin/env bash
# One-time setup for the cloud release workflows (docs/RELEASING.md). Run it
# yourself, on your own machine, with gh logged in as the repo owner. Secrets
# go straight from this terminal into GitHub; none are written to the repo.
#
#   1. a private repo for fastlane match's encrypted certificates
#   2. a deploy key so the workflows can read and write that repo
#   3. the protected `app-store` environment (only you can approve its jobs)
#   4. its secrets and variables: MATCH_PASSWORD (generated), the App Store
#      Connect API key, your Team ID, and the App Review contact details
#
# Safe to re-run: each step asks before replacing something that exists.
# Works in Git Bash on Windows, and on macOS/Linux.
#
# Usage: bin/setup-release-secrets.sh
set -euo pipefail

REPO="yennster/fanficly"
CERTS_REPO="yennster/fanficly-certificates"
ENV_NAME="app-store"

need() { command -v "$1" >/dev/null || { echo "Missing $1" >&2; exit 1; }; }
need gh; need ssh-keygen; need openssl
ask() { local reply; read -r -p "$1 [y/N] " reply; [[ "$reply" =~ ^[Yy] ]]; }
set_secret() { gh secret set "$1" --repo "$REPO" --env "$ENV_NAME"; }   # value on stdin
set_var() { gh variable set "$1" --repo "$REPO" --env "$ENV_NAME" --body "$2"; }
has_secret() { gh secret list --repo "$REPO" --env "$ENV_NAME" --json name --jq '.[].name' | grep -qx "$1"; }

owner_id=$(gh api user --jq .id)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> 1. Private certificates repo ($CERTS_REPO)"
if gh repo view "$CERTS_REPO" >/dev/null 2>&1; then
    echo "    exists"
else
    gh repo create "$CERTS_REPO" --private --description "fastlane match certificates for Fanficly (encrypted)"
fi

echo "==> 2. Protected environment '$ENV_NAME' (you approve every job)"
gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null <<JSON
{"reviewers":[{"type":"User","id":$owner_id}],"prevent_self_review":false,
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null 2>&1 || true
set_var MATCH_GIT_URL "git@github.com:$CERTS_REPO.git"

echo "==> 3. Deploy key for match"
if has_secret MATCH_DEPLOY_KEY && ! ask "    MATCH_DEPLOY_KEY exists. Replace it?"; then
    echo "    kept"
else
    ssh-keygen -q -t ed25519 -N "" -C "fanficly release workflow" -f "$tmp/match"
    gh repo deploy-key add "$tmp/match.pub" --repo "$CERTS_REPO" --allow-write --title "fanficly release workflow $(date +%F)"
    set_secret MATCH_DEPLOY_KEY < "$tmp/match"
fi

echo "==> 4. MATCH_PASSWORD (encrypts the certificates repo)"
if has_secret MATCH_PASSWORD && ! ask "    MATCH_PASSWORD exists. Replace it? (only before signing_setup has run)"; then
    echo "    kept"
else
    pw=$(openssl rand -base64 30 | tr -d '\n/+=')
    printf '%s' "$pw" | set_secret MATCH_PASSWORD
    echo
    echo "    Save this in your password manager as 'Fanficly match password':"
    echo
    echo "        $pw"
    echo
    read -r -p "    Press Enter once it's saved. " _
    unset pw
    clear 2>/dev/null || true
fi

echo "==> 5. App Store Connect API key (Users and Access > Integrations, Admin role)"
if has_secret ASC_KEY_P8 && ! ask "    An API key is set. Replace it?"; then
    echo "    kept"
else
    read -r -p "    Path to the AuthKey_XXXX.p8 file: " p8
    p8="${p8/#\~/$HOME}"; p8="${p8%\"}"; p8="${p8#\"}"
    [ -f "$p8" ] || { echo "No file at $p8" >&2; exit 1; }
    read -r -p "    Key ID: " key_id
    read -r -p "    Issuer ID: " issuer_id
    set_secret ASC_KEY_P8 < "$p8"
    printf '%s' "$key_id" | set_secret ASC_KEY_ID
    printf '%s' "$issuer_id" | set_secret ASC_ISSUER_ID
    echo "    Stored. You can delete the .p8 from this machine; App Store Connect can't re-download it, so keep a copy in your password manager if you want one."
fi

echo "==> 6. Apple Team ID (developer.apple.com > Membership details)"
read -r -p "    Team ID (Enter to keep the current one): " team
[ -z "$team" ] || set_var APPLE_TEAM_ID "$team"

echo "==> 7. App Review contact (shown only to Apple's reviewers)"
if has_secret REVIEW_EMAIL && ! ask "    Contact details are set. Replace them?"; then
    echo "    kept"
else
    for field in FIRST_NAME LAST_NAME EMAIL PHONE; do
        read -r -p "    $field: " value
        printf '%s' "$value" | set_secret "REVIEW_$field"
    done
fi

echo
echo "Done. Next: Actions > Release > Run workflow with lane 'signing_setup' (once),"
echo "then 'pull_metadata'. See docs/RELEASING.md."
