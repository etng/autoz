#!/bin/bash
# AutoZ 构建脚本：把 Sources/ 编成 .app 包（菜单栏程序，无 Dock 图标）
#
# 用法:
#   ./build.sh                构建到 dist/AutoZ.app（默认跟随本机架构）
#   ./build.sh --install      构建后复制到 /Applications
#   ./build.sh --run          构建后直接启动
#
# 环境变量:
#   AUTOZ_VERSION       版本号，写入 Info.plist（默认 0.8.0）
#   AUTOZ_DISPLAY_NAME  对外显示名，写入 CFBundleDisplayName（默认「自适应时区」）
#   AUTOZ_ARCHS         目标架构，空格分隔，如 "arm64 x86_64"（默认本机架构）
#   AUTOZ_MIN_MACOS     最低系统版本（默认 13.0）
#
# 变量引用一律写 ${VAR}，不要写 $VAR 紧跟中文 —— bash 3.2 扫变量名用的是 isalnum()，
# 遇到高位字节（中文首字节）会越界查表，结果随 libc 而异。同一个脚本在本机 macOS 26
# 正常、在 macOS 15 的 CI 上就报 `ARCHS?: unbound variable`。加花括号与 locale 无关，永远安全。
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_NAME="AutoZ"
VERSION="${AUTOZ_VERSION:-0.8.0}"
ARCHS="${AUTOZ_ARCHS:-$(uname -m)}"
HOST_ARCH="$(uname -m)"
MIN_MACOS="${AUTOZ_MIN_MACOS:-13.0}"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
BUILD="$ROOT/build"
BUNDLE_ID="cn.y10n.autoz"
# 对外显示名（Finder / 系统「关于」里看到的那个名字）。改名只动这一处。
DISPLAY_NAME="${AUTOZ_DISPLAY_NAME:-自适应时区}"

echo "==> 清理旧产物"
rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

echo "==> 目标架构: ${ARCHS}（构建机 ${HOST_ARCH}，最低 macOS ${MIN_MACOS}）"

for ARCH in $ARCHS; do
  mkdir -p "$BUILD/$ARCH"

  echo "==> [$ARCH] 编译 C 垫片（转调 AuthorizationExecuteWithPrivileges，Swift 无法直接导入该符号）"
  /usr/bin/clang -c "$ROOT/Sources/authshim.c" -o "$BUILD/$ARCH/authshim.o" \
    -Wno-deprecated-declarations -O2 \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -isysroot "$(xcrun --show-sdk-path)"

  echo "==> [$ARCH] 编译 Swift 主程序"
  /usr/bin/swiftc \
    -O -swift-version 5 \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -framework Security \
    -o "$BUILD/$ARCH/$APP_NAME" \
    "$ROOT/Sources/main.swift" "$ROOT/Sources/artwork.swift" "$ROOT/Sources/ui.swift" \
    "$BUILD/$ARCH/authshim.o"

  echo "==> [$ARCH] 编译特权助手 autoz-helper（免授权通道；launchd 按需拉起，不常驻）"
  /usr/bin/swiftc \
    -O -swift-version 5 \
    -target "$ARCH-apple-macos$MIN_MACOS" \
    -o "$BUILD/$ARCH/autoz-helper" \
    "$ROOT/Sources/helper.swift"
done

# 单架构直接复制，多架构用 lipo 合成通用二进制
join_archs() {
  local out="$1"; shift
  if [[ $# -eq 1 ]]; then
    /bin/cp "$1" "$out"
  else
    /usr/bin/lipo -create "$@" -o "$out"
  fi
}

MAIN_PARTS=(); HELPER_PARTS=()
for ARCH in $ARCHS; do
  MAIN_PARTS+=("$BUILD/$ARCH/$APP_NAME")
  HELPER_PARTS+=("$BUILD/$ARCH/autoz-helper")
done

echo "==> 合成主程序"
join_archs "$APP/Contents/MacOS/$APP_NAME" "${MAIN_PARTS[@]}"
/usr/bin/lipo -info "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    /'

echo "==> 合成特权助手"
join_archs "$APP/Contents/Resources/autoz-helper" "${HELPER_PARTS[@]}"
/bin/chmod +x "$APP/Contents/Resources/autoz-helper"
/usr/bin/lipo -info "$APP/Contents/Resources/autoz-helper" | sed 's/^/    /'

echo "==> 助手自测（11 项协议与安全用例，全部 dry-run，不碰系统）"
"$BUILD/$HOST_ARCH/autoz-helper" --selftest || { echo "助手自测未通过，终止构建"; exit 1; }

echo "==> 生成 App 图标（Sources/artwork.swift 矢量绘制 → AppIcon.icns）"
/usr/bin/swiftc -O -swift-version 5 -parse-as-library \
  -target "$HOST_ARCH-apple-macos$MIN_MACOS" \
  -o "$BUILD/makeicon" \
  "$ROOT/Sources/artwork.swift" "$ROOT/Sources/makeicon.swift"
"$BUILD/makeicon" "$BUILD/AppIcon.iconset"
/usr/bin/iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
echo "    已写入 Resources/AppIcon.icns ($(du -h "$APP/Contents/Resources/AppIcon.icns" | cut -f1))"

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>AutoZ $VERSION</string>
</dict>
</plist>
PLIST

echo "==> 语法检查 Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"

echo "==> ad-hoc 签名（先签嵌套的助手，再签整个 app）"
/usr/bin/codesign --force --sign - --timestamp=none "$APP/Contents/Resources/autoz-helper" 2>&1 | sed 's/^/    /' || true
/usr/bin/codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
/usr/bin/codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> 自检（离线命令）"
"$APP/Contents/MacOS/$APP_NAME" --version | sed 's/^/    /'
"$APP/Contents/MacOS/$APP_NAME" --system | sed 's/^/    /'
"$APP/Contents/MacOS/$APP_NAME" --format | sed 's/^/    /'

echo
echo "构建完成: $APP"
du -sh "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> 安装到 /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  /bin/cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "已安装: /Applications/$APP_NAME.app"
fi

if [[ "${1:-}" == "--run" || "${1:-}" == "--install" ]]; then
  echo "==> 启动"
  /usr/bin/open "/Applications/$APP_NAME.app" 2>/dev/null || /usr/bin/open "$APP"
fi
