#!/usr/bin/env bash
# 自动同步 MotoNav 云编译产物：拉取最新的成功 "Build IPA" 运行并下载 IPA 到 /workspace/output
set -euo pipefail

REPO="kongpeipei/MotoNav-iOS"
WORKFLOW="Build IPA"
ARTIFACT="MotoNav-unsigned"
OUT="/workspace/output"
MARKER="$OUT/.last-run-id"

mkdir -p "$OUT"

LATEST=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 10 \
  --json databaseId,status,conclusion \
  --jq '[.[] | select(.status=="completed" and .conclusion=="success")][0].databaseId' 2>/dev/null || true)

if [ -z "$LATEST" ] || [ "$LATEST" = "null" ]; then
  echo "no successful $WORKFLOW run found"
  exit 0
fi

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$LATEST" ]; then
  echo "up to date (run $LATEST)"
  exit 0
fi

TMP=$(mktemp -d)
gh run download "$LATEST" --repo "$REPO" -n "$ARTIFACT" -D "$TMP" >/dev/null
find "$TMP" -name '*.ipa' -exec cp -f {} "$OUT/" \;
find "$TMP" -name '*.sha256' -exec cp -f {} "$OUT/" \;
rm -rf "$TMP"

echo "$LATEST" > "$MARKER"
echo "downloaded IPA for run $LATEST"
ls -1 "$OUT"