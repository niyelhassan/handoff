#!/bin/zsh
# Runs the native rehearsal: real Safari pages, real Accessibility, real files.
# Requires: the built app allowed under System Settings → Privacy & Security → Accessibility.
# Usage: scripts/native-test.sh [results-dir]
set -euo pipefail
SCOUT_ROOT="${0:A:h:h}"
SCOUT_APP="${SCOUT_APP:-$SCOUT_ROOT/../Routine Scout.app}"
RESULTS="${1:-$SCOUT_ROOT/TestResults/native-$(date +%H%M%S)}"
mkdir -p "$RESULTS"
rm -f "$RESULTS/integration-report.txt"
pkill -f "Routine Scout.app/Contents/MacOS/RoutineScout" 2>/dev/null || true
sleep 1
# Launch through LaunchServices so the app is its own "responsible process" for the Accessibility permission.
# Launching the binary directly from a terminal would make macOS check the terminal's permission instead.
open -n -g "$SCOUT_APP" --args --self-test "$RESULTS" --background --exit-after-test
for _ in {1..900}; do
  if grep -qE '^(PASS|FAIL|BLOCKED)' "$RESULTS/integration-report.txt" 2>/dev/null; then break; fi
  sleep 1
done
echo "--- $RESULTS/integration-report.txt ---"
cat "$RESULTS/integration-report.txt" 2>/dev/null || echo "(no report written)"
echo
sleep 2; pkill -f "RoutineScout --self-test" 2>/dev/null || true
grep -q '^PASS' "$RESULTS/integration-report.txt"
