#!/bin/zsh
# Builds the release binary and wraps it in "Routine Scout.app" next to this package.
# Signing: uses an "Apple Development" identity when one exists so the app's Accessibility
# permission survives rebuilds (ad-hoc signatures change identity on every build).
set -euo pipefail
SCOUT_ROOT="${0:A:h:h}"
cd "$SCOUT_ROOT"
swift build -c release --product RoutineScout 2>&1 | grep -v "not accessible or not writable" || true
test -x .build/release/RoutineScout || { echo "Build failed"; exit 1; }
SCOUT_APP="${SCOUT_APP:-$SCOUT_ROOT/../Routine Scout.app}"
mkdir -p "$SCOUT_APP/Contents/MacOS" "$SCOUT_APP/Contents/Resources"
cp .build/release/RoutineScout "$SCOUT_APP/Contents/MacOS/RoutineScout"
cat > "$SCOUT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Routine Scout</string>
<key>CFBundleDisplayName</key><string>Routine Scout</string>
<key>CFBundleIdentifier</key><string>com.routinescout.app</string>
<key>CFBundleExecutable</key><string>RoutineScout</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Routine Scout reads selected spreadsheet or mail context and runs the app actions you review and approve.</string>
</dict></plist>
PLIST
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier com.routinescout.app --options runtime --timestamp=none "$SCOUT_APP" 2>/dev/null || codesign --force --sign "$IDENTITY" --identifier com.routinescout.app "$SCOUT_APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - --identifier com.routinescout.app "$SCOUT_APP"
  echo "Signed ad hoc (Accessibility must be re-allowed after each rebuild)."
fi
printf 'Built %s\n' "$SCOUT_APP"
