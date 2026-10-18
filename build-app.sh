#!/bin/bash
# 编译并打包成「Groove.app」，放在 build 文件夹里，并安装到「应用程序」文件夹。
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

# 装了 Xcode 时编译成通用版（Apple 芯片 + Intel 都能用）；只有 Command Line Tools 时只能编本机架构
if [[ "$(xcode-select -p)" != *CommandLineTools* ]]; then
  SDK_ARGS+=(--arch arm64 --arch x86_64)
fi

swift build -c release --scratch-path "$SCRATCH" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"}
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} --show-bin-path)"

APP="build/Groove.app"
rm -rf "$APP" "build/本地音乐.app"   # 旧名字的也删掉
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LocalMusic" "$APP/Contents/MacOS/LocalMusic"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"   # 先清掉 Finder 等加的扩展属性，不然签名校验不过
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# 安装到「应用程序」：先退出正在运行的旧版本，再替换。音乐库、歌单、设置都在
# ~/Library/Application Support/LocalMusic，不在 App 里，替换不会丢。
INSTALLED="/Applications/Groove.app"
OLD_INSTALLED="/Applications/本地音乐.app"   # 改名前的旧版本
BUNDLE_ID="com.juan.localmusic"
WAS_RUNNING=0
if pgrep -f "\.app/Contents/MacOS/LocalMusic" >/dev/null; then
  WAS_RUNNING=1
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -f "\.app/Contents/MacOS/LocalMusic" >/dev/null || break
    sleep 0.25
  done
fi
rm -rf "$INSTALLED"
# 只删确实是这个 App 的旧版本（看 bundle id），不碰别的东西
if [[ -d "$OLD_INSTALLED" ]] && [[ "$(plutil -extract CFBundleIdentifier raw "$OLD_INSTALLED/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$OLD_INSTALLED" >/dev/null 2>&1 || true
  rm -rf "$OLD_INSTALLED"
  echo "已删除改名前的旧版本：$OLD_INSTALLED"
fi
ditto "$APP" "$INSTALLED"
# 装好的这份有「Apple Development」证书就重新用它签：签名身份每次都一样，系统给的「屏幕录制」等权限重新编译后还在；
# 没有证书就保持临时签名（每次编译都算新 App，权限会失效）。build 文件夹在「文稿」里，会被系统加上去不掉的扩展属性，
# 用证书签会失败，所以只签「应用程序」里这份。发给别人的 dmg 由 make-dmg.sh 另外签
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
if [[ -n "$SIGN_ID" ]]; then
  xattr -cr "$INSTALLED"
  if codesign --force --sign "$SIGN_ID" "$INSTALLED" >/dev/null 2>&1; then
    echo "签名：$SIGN_ID"
  else
    codesign --force --sign - "$INSTALLED" >/dev/null 2>&1 || true
    echo "用证书签名失败，还是临时签名（重新编译后屏幕录制权限可能要重新打开）"
  fi
fi
touch "$INSTALLED"   # 让 Finder / Dock 刷新图标
# 先登记新版本，否则刚复制完马上打开可能报 -600
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED" >/dev/null 2>&1 || true

echo ""
echo "完成：已安装到 $INSTALLED"
echo "（build 文件夹里也留了一份：$(pwd)/$APP）"
if [[ $WAS_RUNNING == 1 ]]; then
  for _ in 1 2 3; do
    open "$INSTALLED" 2>/dev/null && break
    sleep 1
  done
  echo "旧版本刚才在运行，已经退出并打开了新版本。"
fi
