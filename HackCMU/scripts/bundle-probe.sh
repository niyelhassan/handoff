#!/bin/bash
# Bundles the AX probe as its own signed .app.
#
# WHY a bundle: a bare SwiftPM binary run from a terminal is attributed by TCC
# to the TERMINAL, so it would require granting Accessibility to Terminal
# itself - far more access than this throwaway tool deserves. A separate bundle
# with its own identity keeps the grant scoped, and keeps the probe's TCC
# record from colliding with Handoff's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"

NAME="HandoffProbe"
BUNDLE_ID="com.hackcmu.handoff.probe"
SIGN_ID="${LOOPY_SIGN_ID:-Handoff Dev}"
APP="$ROOT/build/$NAME.app"

"$SWIFT" build -c debug --package-path "$ROOT" --product handoff-probe
BIN="$("$SWIFT" build -c debug --package-path "$ROOT" --show-bin-path)/handoff-probe"

pkill -x "$NAME" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/bin/codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Support/Handoff.entitlements" --timestamp=none "$APP"
echo "==> $APP"
echo "==> run it with:  $APP/Contents/MacOS/$NAME"
