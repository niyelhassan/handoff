#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"

APP_NAME="Handoff"
BUNDLE_ID="com.hackcmu.handoff"
SIGN_ID="${LOOPY_SIGN_ID:-Handoff Dev}"
CONFIG="${LOOPY_CONFIG:-release}"
# FROZEN PATH. TCC keys grants on (bundle id, path). Building somewhere else
# creates a second, independent permission record.
APP="$ROOT/build/$APP_NAME.app"

echo "==> building ($CONFIG)"
"$SWIFT" build -c "$CONFIG" --package-path "$ROOT"
BIN="$("$SWIFT" build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$APP_NAME"

echo "==> assembling $APP"
# Re-signing a running bundle leaves the OLD cdhash resident; macOS will not
# re-evaluate a running image. Kill first.
pkill -x "$APP_NAME" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> signing as '$SIGN_ID'"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  IDENTITY="$SIGN_ID"
else
  echo "!! '$SIGN_ID' not found - falling back to AD-HOC signing."
  echo "!! Accessibility WILL silently break on the next rebuild."
  echo "!! Run: make cert"
  IDENTITY="-"
fi

/usr/bin/codesign --force \
  --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ROOT/Support/$APP_NAME.entitlements" \
  --timestamp=none \
  "$APP"

echo "==> designated requirement:"
/usr/bin/codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    /p'
/usr/bin/codesign --verify --strict "$APP"
echo "==> ok: $APP"
