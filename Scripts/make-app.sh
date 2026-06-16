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

# SPM 资源包（HunkCore 的 languages.json、SwiftTerm 的终端资源等）拷进可执行文件同目录
# Contents/MacOS——Lexer.loadLanguagesJSON 会在此查找。漏拷则语法高亮降级为纯文本。
# 用 find -L 跟随 .build/<config> 软链(指向 .build/<triple>/<config>)，比裸 glob 更稳；
# 找不到资源包直接报错退出，避免 CI 静默打出「无语言表」的残包(曾因此线上启动即崩)。
BUNDLES="$(find -L ".build/$CONFIG" -maxdepth 1 -name "*.bundle" -type d)"
if [ -z "$BUNDLES" ]; then
    echo "❌ .build/$CONFIG 下未找到任何 *.bundle 资源包——打包中止" >&2
    exit 1
fi
echo "$BUNDLES" | while IFS= read -r bundle; do
    cp -R "$bundle" "$APP/Contents/MacOS/"
    echo "  ⬆︎ $(basename "$bundle")"
done
# 语言表是高亮的命脉，单独兜底校验，缺则视为打包失败
if [ ! -e "$APP/Contents/MacOS/Hunk_HunkCore.bundle" ]; then
    echo "❌ Hunk_HunkCore.bundle 未拷入 app——语法高亮会失效，打包中止" >&2
    exit 1
fi

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
