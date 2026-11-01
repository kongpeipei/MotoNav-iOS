#!/usr/bin/env bash
# 版本号自增脚本（每次交付前跑一次）
# 用法: ./.ci/bump_version.sh          # 1.96 -> 1.97
#       ./.ci/bump_version.sh 2.0      # 显式指定新版本
set -euo pipefail

cd "$(dirname "$0")/.."

PBX="MotoNav.xcodeproj/project.pbxproj"
CUR=$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*;' "$PBX" | grep -o '[0-9][0-9.]*')
CUR=${CUR%;}

if [ $# -ge 1 ]; then
  NEW="$1"
else
  # 末位 +1：1.96 -> 1.97
  MAJOR=${CUR%.*}
  MINOR=${CUR##*.}
  NEW="${MAJOR}.$((10#$MINOR + 1))"
fi

if [ "$NEW" = "$CUR" ]; then
  echo "新版本号与当前一致（$CUR），已跳过"
  exit 0
fi

# 1) 工程里所有 target（主 App + Widget）的 MARKETING_VERSION
sed -i '' -E "s/MARKETING_VERSION = ${CUR//./\\.};/MARKETING_VERSION = ${NEW};/g" "$PBX" 2>/dev/null \
  || sed -i -E "s/MARKETING_VERSION = ${CUR//./\\.};/MARKETING_VERSION = ${NEW};/g" "$PBX"

# 2) 设置页显示的版本文字
if grep -q "Text(\"v${CUR}\")" MotoNav/ContentView.swift; then
  sed -i '' -E "s/Text\(\"v${CUR//./\\.}\"\)/Text(\"v${NEW}\")/" MotoNav/ContentView.swift 2>/dev/null \
    || sed -i -E "s/Text\(\"v${CUR//./\\.}\"\)/Text(\"v${NEW}\")/" MotoNav/ContentView.swift
fi

# 3) Build 号（CURRENT_PROJECT_VERSION）必须每次递增
#    自签覆盖安装时若 Build 号不变，iOS 可能沿用旧的可执行文件/缓存 → 表现为"打开就闪退"，
#    卸载重装又恢复正常。所以发版必须让它变。
OLD_BUILD=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*;' "$PBX" | grep -o '[0-9]*')
if [ -n "${OLD_BUILD:-}" ]; then
  NEW_BUILD=$((OLD_BUILD + 1))
  sed -i -E "s/CURRENT_PROJECT_VERSION = ${OLD_BUILD};/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PBX"
  echo "  Build 号: ${OLD_BUILD} -> ${NEW_BUILD}（$(grep -c "CURRENT_PROJECT_VERSION = ${NEW_BUILD};" "$PBX") 处）"
fi

echo "版本号: ${CUR} -> ${NEW}"
echo "  工程 $(grep -c "MARKETING_VERSION = ${NEW};" "$PBX") 处"
grep -n "Text(\"v${NEW}\")" MotoNav/ContentView.swift || true
