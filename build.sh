#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
APP="$ROOT/build/CodeX Usage Bar.app"
ICONSET="$ROOT/build/AppIcon.iconset"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -target "$arch-apple-macosx13.0" -framework AppKit -framework SwiftUI -framework ServiceManagement "$ROOT/CodexQuotaMenu.swift" -o "$ROOT/build/CodexQuotaMenu-$arch"
done
lipo -create "$ROOT/build/CodexQuotaMenu-arm64" "$ROOT/build/CodexQuotaMenu-x86_64" -output "$APP/Contents/MacOS/CodexQuotaMenu"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "$APP"
