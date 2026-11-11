#!/usr/bin/env bash
# 从 tianting-server 已提交的内容同步协议文件（errors.json、schema、vectors），然后重新生成 ErrorCodes.gen.swift。
# 用法：
#   scripts/sync-protocol.sh [tianting-server 检出目录] [提交，默认 HEAD]
#     检出目录默认 ../tianting-server（或旧名 ../im-mvp）。脚本自己用 git archive 取这个提交的 protocol/，
#     不读工作区，工作区里没提交的改动不会被同步（问题 90）。
#   scripts/sync-protocol.sh <git archive 导出的目录> <提交号>
#     目录不是 git 仓库时（例如 `git archive <sha> | tar -x -C 目录` 导出的），提交号必须给出，写进 protocol/SOURCE。
set -euo pipefail
cd "$(dirname "$0")/.."
src="${1:-}"
rev="${2:-HEAD}"
if [ -z "$src" ]; then
  for c in ../tianting-server ../im-mvp; do [ -d "$c/protocol" ] && src="$c" && break; done
fi
[ -n "$src" ] && [ -d "$src" ] || { echo "找不到 tianting-server 检出目录" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
  sha="$(git -C "$src" rev-parse --short "$rev^{commit}")"
  git -C "$src" archive --format=tar "$sha" protocol/errors.json protocol/schema protocol/vectors | tar -x -C "$tmp"
  src_dir="$tmp"
else
  [ $# -ge 2 ] || { echo "$src 不是 git 仓库：请在第二个参数给出导出的提交号" >&2; exit 1; }
  sha="$rev"
  src_dir="$src"
fi
[ -f "$src_dir/protocol/errors.json" ] && [ -d "$src_dir/protocol/schema" ] && [ -d "$src_dir/protocol/vectors" ] \
  || { echo "$src_dir 里没有完整的 protocol/（errors.json、schema、vectors）" >&2; exit 1; }
rm -rf protocol/schema protocol/vectors
cp "$src_dir/protocol/errors.json" protocol/
cp -R "$src_dir/protocol/schema" "$src_dir/protocol/vectors" protocol/
echo "$sha" > protocol/SOURCE
python3 -I scripts/gen-errors/gen_errors.py
echo "已同步到 tianting-server@$(cat protocol/SOURCE)（已提交的内容）"
