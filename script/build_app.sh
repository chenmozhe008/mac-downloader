#!/usr/bin/env bash
# build_app.sh [run|package] —— 编译、打包成 dist/闪电全能下载.app（run 时顺便打开）
# ARCH=arm64|x86_64 指定芯片（默认本机）；本机以外的芯片只打包到 dist/<芯片>/，不会打开
set -euo pipefail
APP_NAME="闪电全能下载"; EXECUTABLE_NAME="Shandian"; BUNDLE_ID="io.github.chenmozhe008.shandian"; APP_VERSION="0.17.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in arm64) GOARCH=arm64 ;; x86_64) GOARCH=amd64 ;; *) echo "ARCH 只能是 arm64 或 x86_64"; exit 1 ;; esac
if [[ "$ARCH" == "$(uname -m)" ]]; then APP="$ROOT/dist/$APP_NAME.app"; else APP="$ROOT/dist/$ARCH/$APP_NAME.app"; fi
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
security find-identity -v -p codesigning 2>/dev/null | grep -q "$CODESIGN_IDENTITY" || CODESIGN_IDENTITY="-"

TRIPLE="$ARCH-apple-macosx14.0"
swift build -c release --triple "$TRIPLE"
BIN="$(swift build -c release --triple "$TRIPLE" --show-bin-path)/$EXECUTABLE_NAME"

# 图标：AppIcon-source.png 更新过才重做 icns
ICNS="$ROOT/Resources/AppIcon.icns"
if [[ ! -f "$ICNS" || "$ROOT/Resources/AppIcon-source.png" -nt "$ICNS" ]]; then
  SET="$ROOT/tmp/AppIcon.iconset"; rm -rf "$SET"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/Resources/AppIcon-source.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ROOT/Resources/AppIcon-source.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICNS"; rm -rf "$SET"
fi

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"  # 「关于 → 更新记录」直接读它
cp "$ROOT/Resources/done.wav" "$APP/Contents/Resources/done.wav"  # 下载完成提示音（script/make_done_sound.py 生成）
cp -R "$ROOT/browser-extension" "$APP/Contents/Resources/BrowserExtension"  # 启动时拷到 Application Support（浏览器认固定路径）
# 打过补丁的内核（script/build_engine.sh 编出来的）；App 启动时发现和本机装的不一样就换上
ENGINE_BIN="/Volumes/Jack Feng/Applications/ShandianBuild/gopeed-shandian-$GOARCH"
if [ -x "$ENGINE_BIN" ]; then cp "$ENGINE_BIN" "$APP/Contents/Resources/gopeed"; else echo "提醒：没找到内核 $ENGINE_BIN，先跑 script/build_engine.sh" >&2; fi
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"  # 声明中文，系统菜单（文件、编辑、窗口）才显示中文
# 强调色（琥珀）：侧栏选中行、按钮等系统控件跟随它；SwiftPM 不编译 xcassets，这里用 actool 单独编
xcrun actool "$ROOT/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --accent-color AccentColor --output-partial-info-plist "$ROOT/tmp/assets-info.plist" >/dev/null
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key><array>
    <dict><key>CFBundleURLName</key><string>磁力链接</string><key>CFBundleURLSchemes</key><array><string>magnet</string></array></dict>
    <dict><key>CFBundleURLName</key><string>ed2k 链接</string><key>CFBundleURLSchemes</key><array><string>ed2k</string></array></dict>
    <dict><key>CFBundleURLName</key><string>闪电全能下载</string><key>CFBundleURLSchemes</key><array><string>shandian</string></array></dict>
  </array>
  <key>CFBundleDocumentTypes</key><array>
    <dict><key>CFBundleTypeName</key><string>BitTorrent 种子</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>org.bittorrent.torrent</string></array>
      <key>CFBundleTypeExtensions</key><array><string>torrent</string></array></dict>
  </array>
</dict></plist>
PLIST
codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "打包完成：$APP"
lipo -info "$APP/Contents/MacOS/$EXECUTABLE_NAME" "$APP/Contents/Resources/gopeed"
if [[ "${1:-run}" == "run" && "$ARCH" == "$(uname -m)" ]]; then pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true; sleep 0.5; open -n "$APP"; fi
