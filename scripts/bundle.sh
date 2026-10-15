#!/usr/bin/env bash
# Build a release binary and wrap it as build/PhotoLab.app (runs locally
# with no developer account). Usage: scripts/bundle.sh [--open]
#
# Signing: PHOTOLAB_SIGN_IDENTITY names the codesign identity, default "-"
# (ad hoc). The Photos permission is keyed to the signature: an ad-hoc one
# changes with every rebuild, so Photos asks again after each bundle.sh;
# a self-signed code-signing certificate in the login keychain (Keychain
# Access > Certificate Assistant, e.g. "PhotoLab Dev") keeps the grant:
#   PHOTOLAB_SIGN_IDENTITY="PhotoLab Dev" scripts/bundle.sh --open
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${PHOTOLAB_SIGN_IDENTITY:--}"
swift build -c release
APP=build/PhotoLab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PhotoLab "$APP/Contents/MacOS/PhotoLab"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PhotoLab</string>
  <key>CFBundleDisplayName</key><string>PhotoLab</string>
  <key>CFBundleIdentifier</key><string>local.photolab</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>PhotoLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryUsageDescription</key><string>PhotoLab opens albums from your Photos library, reads the originals and writes back only what you export or save to Photos; originals are never changed.</string>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"
[[ "${1:-}" == "--open" ]] && open "$APP" || true
