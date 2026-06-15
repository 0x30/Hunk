#!/bin/zsh
# 把 SPM 可执行产物组装成 Hunk.app（输出到 dist/）。
# 用法：Scripts/make-app.sh [debug|release]
# 环境变量：HUNK_VERSION（营销版本）、HUNK_BUILD（构建号）——CI 注入；
#           本地不设时自动从 git 推导：版本 0.1.<提交数>，构建 dev.<短哈希>[+脏标记]。
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Hunk.app"

cd "$ROOT"

# 本地版本号跟随 git：提交数作营销版本尾号，短哈希作构建标识，
# 工作区有未提交改动时加 "+"。构建号保持非纯数字，UpdateChecker 据此识别为开发构建并静默。
GIT_COUNT="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD 2>/dev/null || GIT_HASH="${GIT_HASH}+"
VERSION="${HUNK_VERSION:-0.1.$GIT_COUNT}"
BUILD="${HUNK_BUILD:-dev.$GIT_HASH}"
swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/Hunk" "$APP/Contents/MacOS/Hunk"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SPM 资源包（HunkCore 的 languages.json 等）：Bundle.module 在可执行文件同目录查找，
# 不拷贝则打包版语法高亮的语言表加载不到（降级为纯文本）。
for bundle in ".build/$CONFIG/"*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/MacOS/"
done

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
