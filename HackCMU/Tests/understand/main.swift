import CoreGraphics
import Foundation

// `./handoff understand` - shows exactly what would be sent to Claude Fable 5.1
// for a realistic loop, and, if a key is configured, actually asks it.
//
// Separate from `./handoff test` on purpose: this one costs money and leaves the
// machine, so it is never part of a routine run.

setvbuf(stdout, nil, _IONBF, 0)

let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

func row(_ ordinal: Int) -> AXTarget {
    AXTarget(role: "AXRow", subrole: "AXOutlineRow", title: nil, identifier: nil,
             rolePath: "AXWindow/AXScrollArea/AXOutline/AXRow",
             containerPath: "AXWindow/AXScrollArea/AXOutline",
             containerRole: "AXOutline", containerTitle: "Documents",
             ordinal: ordinal, siblingCount: 31, isEnumerable: true,
             actions: [], url: nil, windowTitle: "Documents",
             itemName: "draft-\(ordinal).txt")
}

func pass(_ ordinal: Int, _ n: Int) -> [Atom] {
    func atom(_ kind: AtomKind, _ label: String, _ key: UInt64,
              detail: String? = nil, target: AXTarget? = nil,
              keyCode: UInt16 = 0, cmd: Bool = false) -> Atom {
        var a = Atom(kind: kind, bundleID: "com.apple.finder", appName: "Finder",
                     strictKey: key, varyKey: target?.varyKey() ?? 0,
                     label: label, detail: detail, start: now, end: now)
        a.target = target
        a.keyCode = keyCode
        a.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
        return a
    }
    let t = row(ordinal)
    return [
        atom(.click, "Click \(t.describe)", 1, target: t),
        atom(.chord, "Press ⌘I", 2, keyCode: 34, cmd: true),
        atom(.text, "Type 8 characters", 3, detail: "report-\(n)"),
        atom(.chord, "Close", 4, keyCode: 13, cmd: true),
    ]
}

let passes = [pass(1, 1), pass(2, 2), pass(3, 3)]
let candidate = LoopCandidate(
    patternID: 1, period: passes.last!, completeReps: 3, partialSteps: 2,
    varyingSteps: [0, 2], recentPasses: passes, confidence: 0.86,
    meanRepSeconds: 6.4, firstStart: now, lastEnd: now)
let plan = LoopPlan(candidate)

print("=== model ===")
print("  \(ClaudeClient.model)   (fallback on refusal: \(ClaudeClient.fallbackModel))")

print("\n=== what Handoff works out on its own ===")
print("  bound     : \(plan.bound)")
print("  advances  : \(plan.advances.map(\.describe).joined(separator: " | "))")
print("  replayable: \(plan.isReplayable)")

let redact = ProcessInfo.processInfo.environment["LOOPY_UNDERSTAND_FULL"] != "1"
print("\n=== payload sent to the model \(redact ? "(structure + hostname - the default)" : "(FULL, opted in)") ===")
let understander = TaskUnderstander()
// Mirror of what `understand` builds, so the exact bytes are inspectable.
print(understander.debugPrompt(candidate, plan).split(separator: "\n")
    .map { "  " + $0 }.joined(separator: "\n"))

let heuristic = TaskUnderstander.heuristic(candidate, plan)
print("\n=== offline fallback (shown instantly, always) ===")
print("  name : \(heuristic.name)")
print("  rest : \(heuristic.restMeans)")

guard understander.isAvailable else {
    print("\n=== live call: SKIPPED ===")
    print("  \(understander.unavailableReason)")
    print("  By default only structure and the site hostname are sent.")
    print("  LOOPY_UNDERSTAND_FULL=1 adds item names, typed text and full URLs.")
    exit(0)
}

print("\n=== live call to \(ClaudeClient.model) ===")
let done = DispatchSemaphore(value: 0)
let started = Date()
understander.understand(candidate, plan: plan) { result in
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "  source: %@  (%.1fs)",
                 result.isFromModel ? "MODEL" : "fell back to heuristic", elapsed))
    print("  name  : \(result.name)")
    print("  rest  : \(result.restMeans)")
    print("  concern: \(result.concern ?? "-")")
    if !result.isFromModel {
        print("\n  The call did not produce a usable answer. Handoff carried on with")
        print("  the offline version, which is the intended behaviour.")
    }
    done.signal()
}
_ = done.wait(timeout: .now() + 90)
