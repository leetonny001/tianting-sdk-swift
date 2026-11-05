#!/usr/bin/env bash
# Copy the protocol files from a tianting-server checkout and regenerate ErrorCodes.gen.swift.
# Usage: scripts/sync-protocol.sh [checkout dir]; defaults to ../tianting-server, then ../im-mvp.
set -euo pipefail
cd "$(dirname "$0")/.."
src="${1:-}"
if [ -z "$src" ]; then
  for c in ../tianting-server ../im-mvp; do [ -d "$c/protocol" ] && src="$c" && break; done
fi
[ -n "$src" ] && [ -d "$src/protocol" ] || { echo "tianting-server checkout not found" >&2; exit 1; }
rm -rf protocol/schema protocol/vectors
cp "$src/protocol/errors.json" protocol/
cp -R "$src/protocol/schema" "$src/protocol/vectors" protocol/
git -C "$src" rev-parse --short HEAD > protocol/SOURCE
python3 -I scripts/gen-errors/gen_errors.py
echo "synced to tianting-server@$(cat protocol/SOURCE)"
