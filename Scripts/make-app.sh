#!/bin/zsh
# 把 SPM 可执行产物组装成 Hunk.app（输出到 dist/）。
# 用法：Scripts/make-app.sh [debug|release]
# 环境变量：HUNK_VERSION（营销版本，默认 0.1.0）、HUNK_BUILD（构建号，CI 注入，默认 dev）
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Hunk.app"
VERSION="${HUNK_VERSION:-0.1.0}"
BUILD="${HUNK_BUILD:-dev}"

cd "$ROOT"
swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/Hunk" "$APP/Contents/MacOS/Hunk"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 声明中英双语言包：AppKit 据此按用户/应用语言加载系统菜单（文件/编辑/窗口…）
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
touch "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" \
      "$APP/Contents/Resources/en.lproj/InfoPlist.strings"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Hunk</string>
    <key>CFBundleDisplayName</key>
    <string>Hunk</string>
    <key>CFBundleIdentifier</key>
    <string>app.hunk.editor</string>
    <key>CFBundleExecutable</key>
    <string>Hunk</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
                <string>public.item</string>
            </array>
        </dict>
    </array>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleAllowMixedLocalizations</key>
    <true/>
</dict>
</plist>
PLIST

# 签名：优先级 HUNK_SIGN_ID 环境变量 > make-dev-cert.sh 记录的名字 > 「Hunk Dev」>
# ad-hoc（每次构建身份都变，TCC 权限会重问）
SIGN_ID="${HUNK_SIGN_ID:-}"
NAME_FILE="$HOME/Library/Application Support/Hunk/sign-identity"
if [ -z "$SIGN_ID" ] && [ -f "$NAME_FILE" ]; then
    SAVED="$(cat "$NAME_FILE")"
    if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SAVED"; then
        SIGN_ID="$SAVED"
    fi
fi
if [ -z "$SIGN_ID" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Hunk Dev"; then
    SIGN_ID="Hunk Dev"
fi
codesign --force --sign "${SIGN_ID:--}" "$APP" 2>/dev/null || true
echo "✅ $APP（签名：${SIGN_ID:-ad-hoc}）"
