#!/usr/bin/env bash
# Configure the read-only deploy key CI uses to check out tianting-server. Run by the repo owner:
# generates a one-off ed25519 key, adds the public half to tianting-server as a read-only deploy key,
# stores the private half as this repo's Actions secret, then deletes the local key files.
# The private key only goes through stdin; it is never printed.
set -euo pipefail
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C tianting-sdk-swift-ci -f "$dir/key"
gh repo deploy-key add "$dir/key.pub" -R leetonny001/tianting-server -t tianting-sdk-swift-ci
gh secret set TIANTING_SERVER_DEPLOY_KEY -R leetonny001/tianting-sdk-swift < "$dir/key"
echo "done: read-only deploy key added to tianting-server, secret set on tianting-sdk-swift, local key removed."
