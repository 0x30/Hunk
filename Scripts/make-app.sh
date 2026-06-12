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
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "✅ $APP"
