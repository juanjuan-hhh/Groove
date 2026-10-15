#!/bin/bash
# 编译并打包成「本地音乐.app」，放在 build 文件夹里，并安装到「应用程序」文件夹。
# 用法：在终端里进入这个文件夹，运行  ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

# 编译产生的临时文件放到缓存目录，避免被 iCloud 同步
SCRATCH="$HOME/Library/Caches/LocalMusicBuild"

# 只装了 Command Line Tools（没有 Xcode）时，macOS 27 SDK 缺少 SwiftUI 宏插件，
# 编译 @State 会失败，所以改用已安装的 macOS 26.x SDK。
SDK_ARGS=()
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  OLD_SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$OLD_SDK" ]] && SDK_ARGS=(--sdk "$OLD_SDK")
fi

swift build -c release --scratch-path "$SCRATCH" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"}
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} --show-bin-path)"

APP="build/本地音乐.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LocalMusic" "$APP/Contents/MacOS/LocalMusic"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# 安装到「应用程序」：先退出正在运行的旧版本，再替换。音乐库、歌单、设置都在
# ~/Library/Application Support/LocalMusic，不在 App 里，替换不会丢。
INSTALLED="/Applications/本地音乐.app"
BUNDLE_ID="com.juan.localmusic"
WAS_RUNNING=0
if pgrep -f "本地音乐.app/Contents/MacOS/LocalMusic" >/dev/null; then
  WAS_RUNNING=1
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -f "本地音乐.app/Contents/MacOS/LocalMusic" >/dev/null || break
    sleep 0.25
  done
fi
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
touch "$INSTALLED"   # 让 Finder / Dock 刷新图标

echo ""
echo "完成：已安装到 $INSTALLED"
echo "（build 文件夹里也留了一份：$(pwd)/$APP）"
if [[ $WAS_RUNNING == 1 ]]; then
  open "$INSTALLED"
  echo "旧版本刚才在运行，已经退出并打开了新版本。"
fi
