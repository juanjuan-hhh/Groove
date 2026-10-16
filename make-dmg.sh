#!/bin/bash
# 把 build-app.sh 装好的 /Applications/Groove.app 做成安装用的 dmg（里面有 Groove 和「应用程序」快捷方式，拖进去就装好了）
# 用法：./make-dmg.sh            → dist/Groove-v<版本号>-macOS.dmg
set -euo pipefail
cd "$(dirname "$0")"
APP=/Applications/Groove.app
[ -d "$APP" ] || { echo "先运行 ./build-app.sh"; exit 1; }
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)
VERSION=${VERSION%.0}   # 1.0.0 → 1.0
OUT="dist/Groove-v$VERSION-macOS.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Groove.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
hdiutil create -volname Groove -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
echo "完成：$OUT（$(du -h "$OUT" | cut -f1)）"
