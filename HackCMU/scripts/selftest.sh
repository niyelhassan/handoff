#!/bin/bash
# Self-test for the detection layer, plus a render of the suggestion window.
#
# WHY not a SwiftPM test target: `swift test` routes through the same broken
# xcodebuild shims as everything else here (see env.sh), and a test target
# cannot import `Handoff` because it is an executable. Compiling the sources
# directly is both simpler and honest about what is being tested.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/env.sh"

OUT="${LOOPY_SELFTEST_OUT:-$ROOT/build/selftest}"
mkdir -p "$OUT"

# Detection only. The capture layer needs an event tap and the UI needs a GUI
# session, so neither belongs in a headless run.
LOGIC_SOURCES=(
  "$ROOT/Sources/Handoff/Detect/Atom.swift"
  "$ROOT/Sources/Handoff/Detect/Normalizer.swift"
  "$ROOT/Sources/Handoff/Detect/LoopDetector.swift"
  "$ROOT/Sources/Handoff/Detect/SemanticOp.swift"
  "$ROOT/Sources/Handoff/Detect/NumberTransform.swift"
  "$ROOT/Sources/Handoff/Detect/TitleTemplate.swift"
  "$ROOT/Sources/Handoff/Detect/TaskValue.swift"
  "$ROOT/Sources/Handoff/Detect/ValueBinding.swift"
  "$ROOT/Sources/Handoff/Library/PatternLibrary.swift"
  "$ROOT/Sources/Handoff/Detect/LoopPlan.swift"
  "$ROOT/Sources/Handoff/Detect/DetectionPipeline.swift"
  "$ROOT/Sources/Handoff/Capture/RawEvent.swift"
  "$ROOT/Sources/Handoff/Suggest/PatternSummary.swift"
  # Compiles and links headlessly; AXIsProcessTrusted() is simply false, so
  # nothing resolves and the coordinate path is what gets exercised.
  "$ROOT/Sources/Handoff/AX/AXAccess.swift"
  "$ROOT/Sources/Handoff/AX/AXTarget.swift"
  "$ROOT/Sources/Handoff/AX/AXResolver.swift"
)

echo "==> building self-test"
"$SWIFTC" -O -swift-version 5 "${LOGIC_SOURCES[@]}" "$ROOT/Tests/main.swift" \
  -o "$OUT/selftest"
"$OUT/selftest"

# The window is worth rendering rather than only compiling: it is laid out by
# SwiftUI, so nothing about its size or whether the buttons fit is knowable
# from a successful build.
echo "==> rendering the suggestion window"
UI_SOURCES=(
  "$ROOT/Sources/Handoff/AX/AXAccess.swift"
  "$ROOT/Sources/Handoff/AX/AXTarget.swift"
  "$ROOT/Sources/Handoff/AX/AXResolver.swift"
  "$ROOT/Sources/Handoff/Detect/Atom.swift"
  "$ROOT/Sources/Handoff/Detect/LoopDetector.swift"
  "$ROOT/Sources/Handoff/Detect/SemanticOp.swift"
  "$ROOT/Sources/Handoff/Detect/NumberTransform.swift"
  "$ROOT/Sources/Handoff/Detect/TitleTemplate.swift"
  "$ROOT/Sources/Handoff/Detect/TaskValue.swift"
  "$ROOT/Sources/Handoff/Detect/ValueBinding.swift"
  "$ROOT/Sources/Handoff/Library/PatternLibrary.swift"
  "$ROOT/Sources/Handoff/Detect/LoopPlan.swift"
  "$ROOT/Sources/Handoff/Understand/ClaudeClient.swift"
  "$ROOT/Sources/Handoff/Understand/TaskUnderstanding.swift"
  "$ROOT/Sources/Handoff/Suggest/PatternSummary.swift"
  "$ROOT/Sources/Handoff/Suggest/SuggestionController.swift"
  "$ROOT/Sources/Handoff/Suggest/SuggestionPanel.swift"
  "$ROOT/Sources/Handoff/Suggest/SuggestionView.swift"
  "$ROOT/Sources/Handoff/Capture/RawEvent.swift"
  "$ROOT/Sources/Handoff/Capture/RawEventRing.swift"
  "$ROOT/Sources/Handoff/Capture/EventTapService.swift"
  "$ROOT/Sources/Handoff/Replay/ReplayEngine.swift"
)
"$SWIFTC" -O -swift-version 5 "${UI_SOURCES[@]}" "$ROOT/Tests/render/main.swift" \
  -o "$OUT/render"
"$OUT/render" "$OUT"
# Opt-in: this one leaves the machine and costs money, so it is never part of
# a routine `./handoff test`.
if [ "${LOOPY_UNDERSTAND:-}" = "1" ]; then
  echo "==> building the understanding check"
  "$SWIFTC" -O -swift-version 5 "${LOGIC_SOURCES[@]}" \
    "$ROOT/Sources/Handoff/Understand/ClaudeClient.swift" \
    "$ROOT/Sources/Handoff/Understand/TaskUnderstanding.swift" \
    "$ROOT/Tests/understand/main.swift" -o "$OUT/understand"
  "$OUT/understand"
fi

echo "==> $OUT"
