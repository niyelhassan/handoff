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
pkill -f "RoutineScout --self-test" 2>/dev/null || true
"$SCOUT_APP/Contents/MacOS/RoutineScout" --self-test "$RESULTS" --background --exit-after-test &
PID=$!
for _ in {1..240}; do
  if grep -qE '^(PASS|FAIL|BLOCKED)' "$RESULTS/integration-report.txt" 2>/dev/null; then break; fi
  kill -0 $PID 2>/dev/null || break
  sleep 1
done
echo "--- $RESULTS/integration-report.txt ---"
cat "$RESULTS/integration-report.txt" 2>/dev/null || echo "(no report written)"
sleep 2; kill $PID 2>/dev/null || true
grep -q '^PASS' "$RESULTS/integration-report.txt"
