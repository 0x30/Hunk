#!/bin/zsh
# 由 make-icon.swift 生成 1024 PNG，再产出 Assets/AppIcon.icns
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swift "$ROOT/Scripts/make-icon.swift" "$TMP/icon-1024.png"

SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$TMP/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$ROOT/Assets"
iconutil -c icns "$SET" -o "$ROOT/Assets/AppIcon.icns"
echo "✅ $ROOT/Assets/AppIcon.icns"
