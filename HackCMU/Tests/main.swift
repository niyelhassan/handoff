import AppKit
import CoreGraphics
import Foundation

// Self-test for the detection layer. Deliberately NOT a SwiftPM test target:
// `swift test` routes through the same xcodebuild shims that are broken on this
// machine (see scripts/env.sh), and the capture and UI layers need a GUI
// session anyway. Run it with `./handoff test`.
//
// Covers normalization, detection, and the two together. The suggestion window
// is verified by rendering it - see scripts/selftest.sh.

setvbuf(stdout, nil, _IONBF, 0)   // a trap otherwise eats every prior line
var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, _ extra: String = "") {
    checks += 1
    print((ok ? "  ok   " : "  FAIL ") + what + (extra.isEmpty ? "" : "  [\(extra)]"))
    if !ok { failures += 1 }
}
func suite(_ name: String) { print("\n── \(name) " + String(repeating: "─", count: max(0, 46 - name.count))) }

let CMD = CGEventFlags.maskCommand.rawValue
let SHIFT = CGEventFlags.maskShift.rawValue
/// Caps lock and the numeric-pad bit ride along in real flags and must not
/// change a chord's identity.
let FLAG_NOISE = CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskNumericPad.rawValue

func utf16Tuple(_ s: String) -> ((UInt16, UInt16, UInt16, UInt16), UInt8) {
    var u = Array(s.utf16); while u.count < 4 { u.append(0) }
    return ((u[0], u[1], u[2], u[3]), UInt8(s.utf16.count))
}

// MARK: - Detector, over synthetic step sequences

func detectorSuite() {
    var clock: UInt64 = 1_000_000_000

    func mk(_ name: Character, vary: UInt64, gap: Double) -> Atom {
        clock += UInt64(gap * 1e9)
        var h = FNV1a(); h.combine(String(name))
        return Atom(kind: .click, bundleID: "app", appName: "App",
                    strictKey: h.value, varyKey: vary,
                    label: "Step \(name)", detail: nil, start: clock, end: clock)
    }

    /// Each character is one step; repeated characters are the same step.
    func run(_ seq: String, vary: [Int] = [], gapAt: [Int: Double] = [:]) -> LoopCandidate? {
        let d = LoopDetector()
        clock = 1_000_000_000
        var last: LoopCandidate?
        for (i, ch) in seq.enumerated() {
            last = d.ingest(mk(ch, vary: vary.contains(i) ? UInt64(i) : 0,
                               gap: gapAt[i] ?? 1.0))
        }
        return last
    }

    suite("detector: speaks up only with two passes plus a step")
    check(run("ABC") == nil, "ABC -> silence (one pass)")
    let two = run("ABCABC")
    check(two?.stepCount == 3, "ABCABC (two full passes) -> fires now", "\(two?.stepCount ?? -1)")
    check(two?.completeReps == 2, "recognised as two complete passes", "\(two?.completeReps ?? -1)")
    let abc = run("ABCABCA")
    check(abc != nil, "ABCABCA -> candidate")
    check(abc?.stepCount == 3, "period is 3 steps", "\(abc?.stepCount ?? -1)")
    check(abc?.completeReps == 2, "two complete passes", "\(abc?.completeReps ?? -1)")
    check(abc?.partialSteps == 1, "one step into the third", "\(abc?.partialSteps ?? -1)")
    check(abc.map { $0.period.map(\.label) } == ["Step A", "Step B", "Step C"],
          "the period offered is the last COMPLETE pass",
          "\(abc?.period.map(\.label) ?? [])")

    suite("detector: shortest period wins, not a harmonic")
    let ab = run("ABABABABA")
    check(ab?.stepCount == 2, "ABABABABA -> period 2, not 4", "\(ab?.stepCount ?? -1)")
    check(ab?.completeReps == 4, "four passes", "\(ab?.completeReps ?? -1)")

    suite("detector: a one-step loop is held to a higher bar")
    check(run("AA") == nil, "AA -> silence (twice is not a habit)")
    check(run("AAA")?.stepCount == 1, "AAA -> period 1 (three clears the unit bar)")
    check(run("AAAA")?.completeReps == 4, "AAAA -> four passes")

    suite("detector: non-repeating input stays quiet")
    check(run("ABCDEFGH") == nil, "ABCDEFGH -> silence")
    let shuffled = run("ABCDBACDBCAD")
    check(shuffled == nil, "shuffled steps -> silence",
          shuffled.map { "found p=\($0.stepCount) reps=\($0.completeReps) partial=\($0.partialSteps) strays=\($0.strayStepsIgnored) period=\($0.period.map(\.label))" } ?? "")

    suite("detector: the loop's parameters are identified")
    let v = run("ABCABCABCA", vary: [1, 4, 7])
    check(v?.varyingSteps == [1], "step 2 changes every pass", "\(v?.varyingSteps ?? [])")
    check(run("ABCABCABCA")?.varyingSteps.isEmpty == true,
          "nothing varies when every pass is identical")

    suite("detector: time gates")
    check(run("ABCABCA", gapAt: [3: 60.0]) == nil,
          "a 60s pause between passes is lunch, not a loop")
    check(run("ABCABCA", gapAt: [3: 20.0]) != nil, "a 20s pause still counts")

    suite("detector: identity survives rotation")
    // The same loop caught mid-pass starts on a different step; "never suggest
    // this" has to silence the task, not one rotation of it.
    let start0 = run("ABCABCA")!, start1 = run("BCABCAB")!
    check(start0.patternID == start1.patternID, "ABC and BCA share a patternID",
          String(format: "%016llx vs %016llx", start0.patternID, start1.patternID))
    check(start0.patternID != run("ABDABDA")!.patternID, "ABC and ABD do not")

    suite("detector: tolerates one stray step per pass")
    // A mis-click (X) in the middle of the second pass.
    let stray = run("ABCABXCABCA")
    check(stray?.stepCount == 3, "ABC ABXC ABC A -> period 3", "\(stray?.stepCount ?? -1)")
    check(stray?.completeReps == 3, "three passes", "\(stray?.completeReps ?? -1)")
    check(stray?.strayStepsIgnored == 1, "one stray ignored", "\(stray?.strayStepsIgnored ?? -1)")
    check(stray.map { $0.period.map(\.label) } == ["Step A", "Step B", "Step C"],
          "the stray is NOT in the period", "\(stray?.period.map(\.label) ?? [])")
    check(stray?.recentPasses.allSatisfy { $0.count == 3 } == true,
          "nor in any pass handed to binding inference")

    // A stray in the FIRST pass - the template must come from a clean one.
    let early = run("AXBCABCABCA")
    check(early?.stepCount == 3 && early?.completeReps == 3,
          "stray in the first pass still lines up", "\(early?.stepCount ?? -1)/\(early?.completeReps ?? -1)")

    // A stray right at the end, after the partial.
    let late = run("ABCABCAX")
    check(late?.stepCount == 3 && late?.completeReps == 2,
          "a stray after the partial step", "\(late?.stepCount ?? -1)/\(late?.completeReps ?? -1)")

    // Two strays in one pass is not tolerated.
    let twoStray = run("ABCAXYBCABCA")
    check(twoStray?.stepCount != 3 || (twoStray?.strayStepsIgnored ?? 0) <= 1,
          "two strays in one pass are not silently absorbed as one task",
          twoStray.map { "p=\($0.stepCount) strays=\($0.strayStepsIgnored)" } ?? "nil")

    // A genuinely alternating task is not flattened into its common prefix.
    let alt = run("ABCABDABCABDA")
    check(alt?.stepCount == 6, "ABC/ABD alternating is a 6-step task, not AB + noise",
          "\(alt?.stepCount ?? -1)")

    check(run("AXBYCZ") == nil, "noise alone is still nothing")

    suite("detector: a longer task")
    let long = run("ABCDEFABCDEFAB")
    check(long?.stepCount == 6, "6-step task detected", "\(long?.stepCount ?? -1)")
    check((long?.confidence ?? 0) > 0.6, "confident",
          String(format: "%.2f", long?.confidence ?? 0))
}

// MARK: - Normalizer, over synthetic raw events

func normalizerSuite() {
    func at(_ s: Double) -> UInt64 { 1_000_000_000 + UInt64(s * 1e9) }

    func keyEvent(_ s: String, code: UInt16 = 0, flags: UInt64 = 0, t: Double,
                  pid: Int32 = 501, repeatKey: Bool = false,
                  secure: Bool = false) -> RawEvent {
        var e = RawEvent()
        e.kind = .keyDown; e.keyCode = code; e.flags = flags; e.pid = pid
        e.hostTime = at(t); e.isAutoRepeat = repeatKey; e.secureInput = secure
        if !secure { let (c, n) = utf16Tuple(s); e.chars = c; e.charCount = n }
        return e
    }
    func clickEvent(x: Float32, y: Float32, t: Double, state: UInt8 = 1,
                    button: UInt8 = 0, pid: Int32 = 501) -> RawEvent {
        var e = RawEvent()
        e.kind = .mouseDown; e.x = x; e.y = y; e.clickState = state
        e.buttonOrAxis = button; e.pid = pid; e.hostTime = at(t)
        return e
    }
    func scrollEvent(_ d: Int32, t: Double) -> RawEvent {
        var e = RawEvent()
        e.kind = .scroll; e.scrollDelta = d; e.pid = 501; e.hostTime = at(t)
        return e
    }
    /// Feeds the events, then ticks far enough forward to close anything open.
    func norm(_ events: [RawEvent]) -> [Atom] {
        var out = [Atom]()
        let n = Normalizer { out.append($0) }
        for e in events { n.consume(e) }
        n.tick(now: at(100))
        return out
    }

    suite("normalizer: typing coalesces into one step")
    let typed = norm([
        keyEvent("h", code: 4, t: 0.0), keyEvent("e", code: 14, t: 0.1),
        keyEvent("l", code: 37, t: 0.2), keyEvent("l", code: 37, t: 0.3),
        keyEvent("o", code: 31, t: 0.4),
    ])
    check(typed.count == 1, "5 keystrokes -> 1 step", "\(typed.count)")
    check(typed.first?.label == "Type 5 characters", "label", typed.first?.label ?? "-")
    check(typed.first?.detail == "hello", "detail carries the text",
          typed.first?.detail ?? "-")
    check(norm([keyEvent("a", code: 0, t: 0), keyEvent("b", code: 11, t: 3.0)]).count == 2,
          "a pause splits the run")

    suite("normalizer: chords are their own step")
    check(norm([keyEvent("c", code: 8, flags: CMD, t: 0)]).first?.label == "Copy",
          "⌘C is labelled by what it does")
    check(norm([keyEvent("\r", code: 0x24, t: 0)]).first?.label == "Confirm",
          "Return likewise")
    check(norm([keyEvent("k", code: 40, flags: CMD, t: 0)]).first?.label == "Press ⌘K",
          "an unnamed chord keeps its glyphs")
    // Arrows arrive as private-use scalars that pass a naive printability test.
    let arrow = norm([keyEvent("\u{F701}", code: 0x7D, t: 0)])
    check(arrow.first?.kind == .chord && arrow.first?.label == "Press ↓",
          "an arrow key is not typed text", arrow.first?.label ?? "-")
    check(norm([keyEvent("k", code: 40, flags: CMD | SHIFT, t: 0)]).first?.label
            == "Press ⇧⌘K", "modifier order matches the menu bar: ⌃⌥⇧⌘")
    check(norm([keyEvent("c", code: 8, flags: CMD, t: 0)])[0].strictKey
            == norm([keyEvent("c", code: 8, flags: CMD | FLAG_NOISE, t: 0)])[0].strictKey,
          "caps lock / keypad bits do not change ⌘C's identity")
    check(norm([
        keyEvent("z", code: 6, flags: CMD, t: 0.0),
        keyEvent("z", code: 6, flags: CMD, t: 0.1, repeatKey: true),
        keyEvent("z", code: 6, flags: CMD, t: 0.2, repeatKey: true),
    ]).count == 1, "a held key is one intent, not thirty")

    suite("normalizer: clicks")
    check(norm([clickEvent(x: 100, y: 200, t: 0)]).first?.kind == .click, "single click")
    let dbl = norm([clickEvent(x: 100, y: 200, t: 0.0, state: 1),
                    clickEvent(x: 100, y: 200, t: 0.2, state: 2)])
    check(dbl.count == 1 && dbl[0].kind == .doubleClick,
          "a double-click is one step, not two", "\(dbl.count)")
    check(norm([clickEvent(x: 10, y: 20, t: 0, button: 1)]).first?.kind == .contextClick,
          "right-click")

    suite("normalizer: click identity - column is the step, row is the value")
    let rowA = norm([clickEvent(x: 400, y: 100, t: 0)])[0]
    let rowB = norm([clickEvent(x: 400, y: 300, t: 0)])[0]
    let colC = norm([clickEvent(x: 900, y: 100, t: 0)])[0]
    check(rowA.strictKey == rowB.strictKey, "two rows of one list are the same step")
    check(rowA.varyKey != rowB.varyKey, "...carrying different values")
    check(rowA.strictKey != colC.strictKey, "a different column is a different step")

    suite("normalizer: scroll, app switches, and our own window")
    let scrolled = norm([scrollEvent(-1, t: 0.0), scrollEvent(-1, t: 0.1),
                         scrollEvent(-1, t: 0.2), scrollEvent(1, t: 0.3)])
    check(scrolled.count == 2, "3 down + 1 up -> 2 steps", "\(scrolled.count)")
    check(scrolled.allSatisfy { !$0.isSignal }, "scroll never takes part in matching")
    let switched = norm([keyEvent("a", code: 0, t: 0.0, pid: 501),
                         keyEvent("b", code: 11, t: 1.0, pid: 777)])
    check(switched.contains { $0.kind == .appSwitch }, "a pid change is a step")
    check(switched.filter { $0.kind == .text }.count == 2, "typing does not cross apps")
    let me = ProcessInfo.processInfo.processIdentifier
    check(norm([clickEvent(x: 10, y: 10, t: 0, pid: me),
                keyEvent("x", code: 7, t: 1.0, pid: me)]).isEmpty,
          "clicking the suggestion window is not input to detect")

    suite("normalizer: secure input")
    let secret = norm([keyEvent("", code: 0, t: 0.0, secure: true),
                       keyEvent("", code: 1, t: 0.1, secure: true),
                       keyEvent("", code: 2, t: 0.2, secure: true)])
    check(secret.count == 1 && secret[0].kind == .text,
          "a password still produces a step, so the loop stays detectable")
    check(secret[0].detail == nil, "no content is kept")
    check(secret[0].label.contains("hidden"), "and it says so", secret[0].label)

    suite("normalizer: text identity - same field, different value")
    let t1 = norm([keyEvent("a", code: 0, t: 0)])[0]
    let t2 = norm([keyEvent("z", code: 6, t: 0)])[0]
    check(t1.strictKey == t2.strictKey, "typing is one step whatever is typed")
    check(t1.varyKey != t2.varyKey, "...with the value marked as the variable")
}

// MARK: - Both together, over a plausible task

func endToEndSuite() {
    var t = 0.0
    var stream: [RawEvent] = []

    func key(_ s: String, _ code: UInt16, _ flags: UInt64 = 0) {
        var e = RawEvent()
        e.kind = .keyDown; e.keyCode = code; e.flags = flags; e.pid = 900
        e.hostTime = UInt64(t * 1e9)
        let (c, n) = utf16Tuple(s); e.chars = c; e.charCount = n
        stream.append(e); t += 0.09
    }
    func typeText(_ s: String) { for ch in s { key(String(ch), 0) } }
    func click(_ x: Float32, _ y: Float32) {
        var e = RawEvent()
        e.kind = .mouseDown; e.x = x; e.y = y; e.clickState = 1; e.pid = 900
        e.hostTime = UInt64(t * 1e9)
        stream.append(e); t += 0.6
    }

    // Pick the next file in a Finder list, open Get Info, rename it, close.
    // The row moves down the list every pass and the name differs every pass;
    // everything else is identical. Three passes, then caught starting a fourth.
    let rows: [Float32] = [220, 244, 268, 292]
    for (pass, y) in rows.enumerated() {
        click(500, y)
        if pass == rows.count - 1 { break }
        key("i", 34, CMD); t += 0.5
        typeText("report-\(pass)")
        t += 0.4
        key("w", 13, CMD); t += 0.9
    }

    // A box rather than a captured var: the pipeline's callbacks are @Sendable
    // (they really do fire on the enrich queue in the app), so capturing a
    // local `var` is a hard error under Swift 6.
    final class Box: @unchecked Sendable { var items = [LoopCandidate]() }

    let pipeline = DetectionPipeline()
    let seen = Box()
    pipeline.onCandidate = { seen.items.append($0) }
    for e in stream { pipeline.consume(e) }
    pipeline.tick(now: UInt64((t + 5) * 1e9))
    let candidates = seen.items

    suite("end to end: a Finder rename loop")
    check(!candidates.isEmpty, "detected", "\(candidates.count) reports")
    guard let c = candidates.last else { return }
    check(c.stepCount == 4, "4-step period", "\(c.stepCount)")
    check(c.completeReps == 3, "three complete passes", "\(c.completeReps)")
    check(c.partialSteps == 1, "one step into the fourth", "\(c.partialSteps)")
    check(c.varyingSteps.sorted() == [0, 2], "the row and the name are the parameters",
          "\(c.varyingSteps.sorted())")
    check(c.confidence > 0.7, "confident", String(format: "%.2f", c.confidence))

    // Starting to watch mid-pass must reach the same task.
    let mid = DetectionPipeline()
    let midSeen = Box()
    mid.onCandidate = { midSeen.items.append($0) }
    for e in stream.dropFirst(1) { mid.consume(e) }
    mid.tick(now: UInt64((t + 5) * 1e9))
    check(midSeen.items.last?.patternID == c.patternID,
          "a mid-pass start reaches the same patternID",
          String(format: "%016llx", midSeen.items.last?.patternID ?? 0))

    suite("end to end: what the window will say")
    let s = PatternSummary(c)
    print("      ┌─────────────────────────────────────────")
    print("      │ Handoff spotted a pattern              [×]")
    print("      │ \(s.headline)")
    print("      │ [ \(s.title) ]")
    print("      │ \(s.evidence)   \(Int(s.confidence * 100))%")
    for step in s.steps {
        print("      │  \(step.id + 1). \(step.text)"
              + (step.varies ? "  (varies)" : "")
              + (step.detail.map { "  \u{201C}\($0)\u{201D}" } ?? ""))
    }
    if let n = s.parameterNote { print("      │ ⑂ \(n)") }
    print("      │ Never          [Not now] [Automate the rest]")
    print("      └─────────────────────────────────────────")
    check(s.steps.count == 4, "every step is listed")
    check(s.steps.filter(\.varies).count == 2, "both parameters are flagged")
    check(s.parameterNote != nil, "and called out in words")
    check(!s.headline.contains("pid:"), "no internal placeholder leaks into the copy")
}

// MARK: - Loop plan: what "the rest" means

func planSuite() {
    var clock: UInt64 = 1_000_000_000

    func row(_ ordinal: Int, of n: Int, container: String = "Documents") -> AXTarget {
        AXTarget(role: "AXRow", subrole: "AXOutlineRow", title: nil, identifier: nil,
                 rolePath: "AXWindow/AXScrollArea/AXOutline/AXRow",
                 containerPath: "AXWindow/AXScrollArea/AXOutline",
                 containerRole: "AXOutline", containerTitle: container,
                 ordinal: ordinal, siblingCount: n, isEnumerable: true,
                 actions: [], url: nil, windowTitle: container,
                 itemName: "file-\(ordinal).txt")
    }

    func atom(_ kind: AtomKind, _ label: String, key: UInt64,
              target: AXTarget? = nil, detail: String? = nil,
              bundle: String = "com.apple.finder") -> Atom {
        clock += 500_000_000
        var a = Atom(kind: kind, bundleID: bundle,
                     appName: bundle == "com.apple.finder" ? "Finder" : "Excel",
                     strictKey: key, varyKey: target.map { $0.varyKey() } ?? 0,
                     label: label, detail: detail, start: clock, end: clock)
        a.target = target
        return a
    }

    /// A candidate whose step 0 walks a list and whose step 2 types a name.
    func candidate(ordinals: [Int], of n: Int, names: [String],
                   bundle: String = "com.apple.finder") -> LoopCandidate {
        var passes: [[Atom]] = []
        for (o, name) in zip(ordinals, names) {
            passes.append([
                atom(.click, "Click row", key: 1, target: row(o, of: n), bundle: bundle),
                atom(.chord, "Press ⌘I", key: 2, bundle: bundle),
                atom(.text, "Type a name", key: 3, detail: name, bundle: bundle),
            ])
        }
        return LoopCandidate(
            patternID: 7, period: passes.last!, completeReps: passes.count,
            partialSteps: 1, varyingSteps: [0, 2], recentPasses: passes,
            confidence: 0.9, meanRepSeconds: 3, firstStart: 0, lastEnd: clock)
    }

    suite("plan: walking a list gives a real bound")
    let p1 = LoopPlan(candidate(ordinals: [0, 1, 2], of: 31,
                                names: ["report-0", "report-1", "report-2"]))
    check(p1.bound == .known(remaining: 28, total: 31, source: "Documents"),
          "28 of 31 rows left after three passes", "\(p1.bound)")
    check(p1.advances.contains { if case .ordinal(1, "Documents") = $0.rule { return true }; return false },
          "step 1 advances one row per pass")
    check(p1.advances.contains { $0.binding == .counter(prefix: "report-", next: 3, stride: 1) },
          "step 3 will type report-3 next",
          p1.advances.map(\.describe).joined(separator: " | "))
    check(p1.canPredictEveryParameter, "every parameter is predictable")
    check(p1.isReplayable, "and it is replayable", p1.blockers.joined(separator: "; "))
    check(p1.headline.contains("28 more times"), "headline", p1.headline)

    suite("plan: a stride of two is not a stride of one")
    let p2 = LoopPlan(candidate(ordinals: [0, 2, 4], of: 21,
                                names: ["a-0", "a-2", "a-4"]))
    check(p2.bound == .known(remaining: 8, total: 21, source: "Documents"),
          "every other row: 8 left, not 16", "\(p2.bound)")

    suite("plan: refuses to guess what it cannot predict")
    let p3 = LoopPlan(candidate(ordinals: [0, 1, 2], of: 9,
                                names: ["kickoff", "budget", "retro"]))
    check(!p3.canPredictEveryParameter, "arbitrary names are not a sequence")
    check(!p3.isReplayable, "so the loop is not replayable unattended")
    check(p3.blockers.contains { $0.contains("Step 3")
            && $0.contains("cannot tell where the value comes from") },
          "and it says which step", p3.blockers.joined(separator: "; "))

    suite("plan: a loop with no list has no number")
    var noList = candidate(ordinals: [0, 1, 2], of: 31,
                           names: ["report-0", "report-1", "report-2"])
    noList = LoopCandidate(
        patternID: noList.patternID,
        period: noList.period.map { a in var b = a; b.target = nil; return b },
        completeReps: noList.completeReps, partialSteps: noList.partialSteps,
        varyingSteps: [2],
        recentPasses: noList.recentPasses.map { $0.map { a in var b = a; b.target = nil; return b } },
        confidence: noList.confidence, meanRepSeconds: noList.meanRepSeconds,
        firstStart: noList.firstStart, lastEnd: noList.lastEnd)
    let p4 = LoopPlan(noList)
    if case .unknown = p4.bound { check(true, "bound is honestly unknown") }
    else { check(false, "bound is honestly unknown", "\(p4.bound)") }
    check(!p4.isReplayable, "and that alone blocks unattended replay")
    check(p4.headline.contains("cannot tell how many"), "headline says so", p4.headline)

    suite("plan: the end of the list")
    let p5 = LoopPlan(candidate(ordinals: [27, 28, 29], of: 30,
                                names: ["x-1", "x-2", "x-3"]))
    check(p5.bound == .exhausted(source: "Documents"), "nothing left after the last row",
          "\(p5.bound)")

    suite("plan: only Finder and Safari can be driven")
    let p6 = LoopPlan(candidate(ordinals: [0, 1, 2], of: 31,
                                names: ["report-0", "report-1", "report-2"],
                                bundle: "com.microsoft.Excel"))
    check(!p6.isReplayable, "an unsupported app blocks replay")
    check(p6.blockers.contains { $0.contains("Finder and Safari") && $0.contains("Excel") },
          "and names the app it cannot drive", p6.blockers.joined(separator: "; "))
}

// MARK: - Value bindings: where a changing value comes from

func bindingSuite() {
    var clock: UInt64 = 0

    func source(_ texts: [String], ordinal: Int) -> AXTarget {
        AXTarget(role: "AXRow", subrole: nil, title: nil, identifier: nil,
                 rolePath: "AXWindow/AXTable/AXRow", containerPath: "AXWindow/AXTable",
                 containerRole: "AXTable", containerTitle: "Assignments",
                 ordinal: ordinal, siblingCount: 12, isEnumerable: true,
                 actions: [], url: "https://canvas.example.edu/courses/1/assignments",
                 windowTitle: "Assignments", itemName: texts.first, texts: texts)
    }

    func atom(_ kind: AtomKind, _ label: String, key: UInt64,
              text: String? = nil, target: AXTarget? = nil,
              keyCode: UInt16 = 0, cmd: Bool = false) -> Atom {
        clock += 400_000_000
        var a = Atom(kind: kind, bundleID: "com.apple.Safari", appName: "Safari",
                     strictKey: key, varyKey: target?.varyKey() ?? 0,
                     label: label, detail: text, start: clock, end: clock)
        a.fullText = text
        a.target = target
        a.keyCode = keyCode
        a.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
        return a
    }

    suite("binding: a typed value read off the row that was opened")
    // Canvas -> Calendar: click an assignment row, switch app, type its title.
    let titles = [["Essay draft", "Due Oct 3"],
                  ["Lab report", "Due Oct 7"],
                  ["Midterm review", "Due Oct 9"]]
    var passes: [[Atom]] = []
    for (i, t) in titles.enumerated() {
        passes.append([
            atom(.click, "Click row", key: 1, target: source(t, ordinal: i)),
            atom(.appSwitch, "Switch to Calendar", key: 2),
            atom(.text, "Type a title", key: 3, text: t[0]),
        ])
    }
    let b = BindingInference.binding(forStep: 2, in: passes)
    check(b == .fromElement(step: 0, textIndex: 0, sample: "Midterm review"),
          "step 3 types the title of the row clicked in step 1", "\(b)")
    check(b.isActionable, "so it is actionable")

    suite("binding: the SECOND field of the same row")
    var datePasses: [[Atom]] = []
    clock = 0
    for (i, t) in titles.enumerated() {
        datePasses.append([
            atom(.click, "Click row", key: 1, target: source(t, ordinal: i)),
            atom(.text, "Type a date", key: 3, text: t[1]),
        ])
    }
    let d = BindingInference.binding(forStep: 1, in: datePasses)
    check(d == .fromElement(step: 0, textIndex: 1, sample: "Due Oct 9"),
          "the due date is a different column of the same row", "\(d)")

    suite("binding: copy then paste needs no understanding")
    var clipPasses: [[Atom]] = []
    clock = 0
    for (i, t) in titles.enumerated() {
        clipPasses.append([
            atom(.click, "Click row", key: 1, target: source(t, ordinal: i)),
            atom(.chord, "Press ⌘C", key: 2, keyCode: 8, cmd: true),
            atom(.appSwitch, "Switch to Calendar", key: 3),
            atom(.chord, "Press ⌘V", key: 4, keyCode: 9, cmd: true),
        ])
    }
    let clip = BindingInference.binding(forStep: 3, in: clipPasses)
    check(clip == .viaClipboard(copiedAtStep: 1), "paste is bound to the copy", "\(clip)")

    suite("binding: refuses a coincidence")
    // The typed value matches nothing on screen and follows no sequence.
    var randomPasses: [[Atom]] = []
    clock = 0
    for (i, t) in titles.enumerated() {
        randomPasses.append([
            atom(.click, "Click row", key: 1, target: source(t, ordinal: i)),
            atom(.text, "Type a note", key: 3,
                 text: ["asdf", "qwerty", "zxcvb"][i]),
        ])
    }
    let r = BindingInference.binding(forStep: 1, in: randomPasses)
    check(!r.isActionable, "unrelated text is not a binding", "\(r)")

    suite("binding: one lucky pass is not a relationship")
    // Pass 1's typed text happens to match the row; later passes do not.
    var flukePasses: [[Atom]] = []
    clock = 0
    let typed = ["Essay draft", "something else", "another thing"]
    for (i, t) in titles.enumerated() {
        flukePasses.append([
            atom(.click, "Click row", key: 1, target: source(t, ordinal: i)),
            atom(.text, "Type", key: 3, text: typed[i]),
        ])
    }
    let fluke = BindingInference.binding(forStep: 1, in: flukePasses)
    check(!fluke.isActionable, "a single coincidence is rejected", "\(fluke)")
}

// MARK: - Semantic operations

func semanticSuite() {
    let cmd = CGEventFlags.maskCommand.rawValue
    let shift = CGEventFlags.maskShift.rawValue
    suite("semantics: keystrokes become operations")
    check(SemanticOp.classify(keyCode: 8, modifiers: cmd) == .copy, "⌘C is Copy")
    check(SemanticOp.classify(keyCode: 9, modifiers: cmd) == .paste, "⌘V is Paste")
    check(SemanticOp.classify(keyCode: 9, modifiers: cmd | shift) == .paste,
          "⇧⌘V (paste and match style) is still Paste")
    check(SemanticOp.classify(keyCode: 0x30, modifiers: cmd) == .switchApp, "⌘⇥ is Switch app")
    check(SemanticOp.classify(keyCode: 0x24, modifiers: cmd) == .send, "⌘↩ is Send")
    check(SemanticOp.classify(keyCode: 0x33, modifiers: cmd) == .trash, "⌘⌫ is Move to Trash")
    check(SemanticOp.classify(keyCode: 8, modifiers: 0) == nil, "a bare C is typing, not an op")
    check(SemanticOp.classify(keyCode: 0x30, modifiers: 0) == .nextField, "⇥ moves to the next field")

    func chord(_ code: UInt16, _ mods: UInt64) -> Atom {
        var a = Atom(kind: .chord, bundleID: "x", appName: "X", strictKey: 1,
                     varyKey: 0, label: "", detail: nil, start: 0, end: 0)
        a.keyCode = code; a.modifiers = mods
        return a
    }
    suite("semantics: ⌘⇥ is not its own step")
    check(!chord(0x30, cmd).isSignal, "⌘⇥ is subsumed by the app switch it causes")
    check(chord(8, cmd).isSignal, "⌘C is a real step")
    check(chord(8, cmd).operation?.movesData == true, "and it moves data")
    check(chord(0x24, cmd).operation?.isCommit == true, "⌘↩ commits")
}

// MARK: - Worth automating?

func valueSuite() {
    var clock: UInt64 = 0
    func atom(_ kind: AtomKind, _ key: UInt64, bundle: String = "com.apple.finder",
              keyCode: UInt16 = 0, cmd: Bool = false, target: AXTarget? = nil,
              text: String? = nil) -> Atom {
        clock += 300_000_000
        var a = Atom(kind: kind, bundleID: bundle, appName: bundle, strictKey: key,
                     varyKey: target?.varyKey() ?? 0, label: "s", detail: text,
                     start: clock, end: clock)
        a.keyCode = keyCode
        a.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
        a.target = target
        a.fullText = text
        return a
    }
    func row(_ o: Int) -> AXTarget {
        AXTarget(role: "AXRow", subrole: nil, title: nil, identifier: nil,
                 rolePath: "AXWindow/AXOutline/AXRow", containerPath: "AXWindow/AXOutline",
                 containerRole: "AXOutline", containerTitle: "list", ordinal: o,
                 siblingCount: 20, isEnumerable: true, actions: [], url: nil,
                 windowTitle: nil, itemName: nil, texts: [])
    }
    func value(_ passes: [[Atom]], varying: Set<Int> = []) -> TaskValue {
        let c = LoopCandidate(patternID: 1, period: passes.last!, completeReps: passes.count,
                              partialSteps: 1, varyingSteps: varying, recentPasses: passes,
                              confidence: 0.8, meanRepSeconds: 2, firstStart: 0, lastEnd: 0)
        return LoopPlan(c).value
    }

    suite("value: repetition alone is not a task")
    let typing = value([[atom(.text, 1, text: "hello")], [atom(.text, 1, text: "there")]], varying: [0])
    check(!typing.isWorthOffering, "pure typing is vetoed", typing.vetoes.first ?? "-")
    let keys = value([[atom(.chord, 1, keyCode: 106), atom(.chord, 2, keyCode: 107)],
                      [atom(.chord, 1, keyCode: 106), atom(.chord, 2, keyCode: 107)]])
    check(!keys.isWorthOffering, "two function keys over and over is vetoed", keys.vetoes.first ?? "-")

    suite("value: real tasks clear the bar")
    let rename = value([
        [atom(.click, 1, target: row(0)), atom(.chord, 2, keyCode: 34, cmd: true),
         atom(.text, 3, text: "a-1"), atom(.chord, 4, keyCode: 13, cmd: true)],
        [atom(.click, 1, target: row(1)), atom(.chord, 2, keyCode: 34, cmd: true),
         atom(.text, 3, text: "a-2"), atom(.chord, 4, keyCode: 13, cmd: true)],
    ], varying: [0, 2])
    check(rename.isWorthOffering, "walking a list and renaming each item",
          rename.reasons.joined(separator: "; "))

    let copyAcross = value([
        [atom(.click, 1, target: row(0)), atom(.chord, 2, keyCode: 8, cmd: true),
         atom(.appSwitch, 3, bundle: "com.apple.mail"), atom(.chord, 4, keyCode: 9, cmd: true)],
        [atom(.click, 1, target: row(1)), atom(.chord, 2, keyCode: 8, cmd: true),
         atom(.appSwitch, 3, bundle: "com.apple.mail"), atom(.chord, 4, keyCode: 9, cmd: true)],
    ], varying: [0])
    check(copyAcross.isWorthOffering, "copy, switch app, paste", copyAcross.reasons.joined(separator: "; "))
    check(copyAcross.reasons.contains { $0.contains("moves data") }, "credited for moving data")
    check(copyAcross.reasons.contains { $0.contains("crosses") }, "and for crossing apps")

    let eachCheckbox = value([[atom(.click, 1, target: row(0))],
                              [atom(.click, 1, target: row(1))],
                              [atom(.click, 1, target: row(2))],
                              [atom(.click, 1, target: row(3))]], varying: [0])
    check(eachCheckbox.isWorthOffering, "clicking each item in a list", eachCheckbox.reasons.joined(separator: "; "))
}

// MARK: - Correction noise

func noiseSuite() {
    func chord(_ code: UInt16, cmd: Bool = false) -> Atom {
        var a = Atom(kind: .chord, bundleID: "x", appName: "X", strictKey: 1,
                     varyKey: 0, label: "k", detail: nil, start: 0, end: 0)
        a.keyCode = code
        a.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
        return a
    }
    suite("noise: repetitive but not automatable")
    check(!chord(0x33).isSignal, "backspace is not a step")
    check(!chord(0x75).isSignal, "forward delete is not a step")
    check(chord(0x33, cmd: true).isSignal, "⌘⌫ IS a step - that is Move to Trash")
    check(chord(0x24).isSignal, "Return is still a step")
    var scroll = Atom(kind: .scroll, bundleID: "x", appName: "X", strictKey: 1,
                      varyKey: 0, label: "s", detail: nil, start: 0, end: 0)
    scroll.keyCode = 0
    check(!scroll.isSignal, "scrolling is not a step")
}

// MARK: - Pattern library and prefix recognition

func librarySuite() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("handoff-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    func atom(_ key: UInt64, _ label: String = "step") -> Atom {
        Atom(kind: .chord, bundleID: "com.apple.Safari", appName: "Safari",
             strictKey: key, varyKey: 0, label: label, detail: nil,
             start: 0, end: 0)
    }
    func candidate(_ keys: [UInt64]) -> LoopCandidate {
        let period = keys.map { atom($0) }
        return LoopCandidate(patternID: LoopDetector.patternID(keys), period: period,
                             completeReps: 3, partialSteps: 1, varyingSteps: [],
                             recentPasses: [period], confidence: 0.9,
                             meanRepSeconds: 4, firstStart: 0, lastEnd: 0)
    }

    suite("library: recognises a known task from its opening steps")
    let lib = PatternLibrary(url: tmp)
    let c = candidate([11, 22, 33, 44])
    lib.remember(c, plan: LoopPlan(c), name: "Copy assignment to calendar")

    check(lib.recognisePrefix(in: [atom(11)]) == nil,
          "one step is not enough evidence")
    let hit = lib.recognisePrefix(in: [atom(11), atom(22)])
    check(hit?.0.name == "Copy assignment to calendar", "two steps in, it knows",
          hit?.0.name ?? "nil")
    check(hit?.matched == 2, "and how far in you are", "\(hit?.matched ?? -1)")
    check(lib.recognisePrefix(in: [atom(99), atom(98)]) == nil,
          "an unrelated opening matches nothing")
    check(lib.recognisePrefix(in: [atom(22), atom(33)]) == nil,
          "the MIDDLE of a task is not its opening")
    // Earlier unrelated steps must not stop the opening from being seen.
    check(lib.recognisePrefix(in: [atom(77), atom(11), atom(22), atom(33)])?.matched == 3,
          "matches the longest opening at the end of the stream")

    suite("library: a rejection is permanent")
    lib.reject(c.patternID, reason: "these are different courses")
    check(lib.recognisePrefix(in: [atom(11), atom(22)]) == nil,
          "a rejected task is never offered again")
    check(lib.isRejected(c.patternID), "and is recorded as rejected")

    suite("library: survives a restart")
    let c2 = candidate([5, 6, 7])
    lib.remember(c2, plan: LoopPlan(c2), name: "Log the shift hours")
    lib.recordChoices(c2.patternID, name: "Log hours", runs: 7, stopBeforeCommit: false)

    let reopened = PatternLibrary(url: tmp)
    let again = reopened.recognisePrefix(in: [atom(5), atom(6)])
    check(again?.0.name == "Log hours", "the name the user chose came back",
          again?.0.name ?? "nil")
    check(again?.0.preferredRuns == 7, "so did the run count",
          "\(again?.0.preferredRuns ?? -1)")
    check(reopened.isRejected(c.patternID), "and so did the rejection")

    suite("library: a remembered task can be RUN, not just named")
    // Learn a Finder rename loop with real structure, then come back to it.
    func row(_ o: Int, of n: Int) -> AXTarget {
        AXTarget(role: "AXRow", subrole: nil, title: nil, identifier: nil,
                 rolePath: "AXWindow/AXScrollArea/AXOutline/AXRow",
                 containerPath: "AXWindow/AXScrollArea/AXOutline",
                 containerRole: "AXOutline", containerTitle: "list view",
                 ordinal: o, siblingCount: n, isEnumerable: true, actions: [],
                 url: nil, windowTitle: "Documents", itemName: "secret-\(o).txt",
                 texts: ["secret-\(o).txt", "Today"])
    }
    func rich(_ kind: AtomKind, _ key: UInt64, target: AXTarget? = nil,
              text: String? = nil, keyCode: UInt16 = 0, cmd: Bool = false) -> Atom {
        var a = Atom(kind: kind, bundleID: "com.apple.finder", appName: "Finder",
                     strictKey: key, varyKey: target?.varyKey() ?? 0, label: "s",
                     detail: text, start: 0, end: 0)
        a.target = target; a.fullText = text; a.keyCode = keyCode
        a.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
        return a
    }
    var learnPasses: [[Atom]] = []
    for i in 0..<3 {
        learnPasses.append([
            rich(.click, 101, target: row(i, of: 31)),
            rich(.chord, 102, keyCode: 34, cmd: true),
            rich(.text, 103, text: "secret-\(i).txt"),     // reads the row's name
            rich(.chord, 104, keyCode: 13, cmd: true),
        ])
    }
    let learned = LoopCandidate(patternID: LoopDetector.patternID([101, 102, 103, 104]),
                                period: learnPasses.last!, completeReps: 3, partialSteps: 1,
                                varyingSteps: [0, 2], recentPasses: learnPasses,
                                confidence: 0.9, meanRepSeconds: 4, firstStart: 0, lastEnd: 0)
    let learnedPlan = LoopPlan(learned)
    check(learnedPlan.advances.contains { $0.binding == .fromElement(step: 0, textIndex: 0, sample: "secret-2.txt") },
          "while learning, the typed name was bound to the row")
    let lib2 = PatternLibrary(url: tmp)
    lib2.remember(learned, plan: learnedPlan, name: "Rename each file")

    // A week later: a different folder, 12 files, the user clicks row 4 and
    // presses ⌘I. Two steps in, Handoff should know - and know how many are left.
    let reopened2 = PatternLibrary(url: tmp)
    let liveTail = [rich(.click, 101, target: row(4, of: 12)),
                    rich(.chord, 102, keyCode: 34, cmd: true)]
    guard let (hit2, matched2) = reopened2.recognisePrefix(in: liveTail) else {
        check(false, "recognised after two steps"); return
    }
    check(matched2 == 2, "two steps matched", "\(matched2)")
    check(hit2.isRunnable, "the stored pattern carries replay structure")
    guard let rebuilt = hit2.candidate(liveTail: liveTail, now: 1) else {
        check(false, "a candidate can be rebuilt"); return
    }
    check(rebuilt.stepCount == 4, "all four steps are back", "\(rebuilt.stepCount)")
    check(rebuilt.period[0].target?.siblingCount == 12,
          "the opening step is the LIVE click - today's list has 12 rows, not 31")
    check(rebuilt.period[3].keyCode == 13 && rebuilt.period[3].modifiers != 0,
          "the remembered ⌘W can be pressed again")
    let plan2 = hit2.plan(for: rebuilt)
    check(plan2.bound == .known(remaining: 7, total: 12, source: "list view"),
          "bound re-read from today's list: 7 rows after row 5", "\(plan2.bound)")
    check(plan2.advances.contains { if case .value(.fromElement(0, 0, _)) = $0.rule { return true }; return false },
          "the name binding came back as a relation")
    check(plan2.isReplayable, "and it is replayable", plan2.blockers.joined(separator: "; "))

    suite("library: a fromScreen task survives a restart and stays runnable")
    func screenAtom(_ kind: AtomKind, _ key: UInt64, bundle: String, app: String,
                    keyCode: UInt16 = 0, cmd: Bool = false, target: AXTarget? = nil,
                    text: String? = nil, screen: [ScreenReadout] = []) -> Atom {
        var a = Atom(kind: kind, bundleID: bundle, appName: app, strictKey: key,
                     varyKey: target?.varyKey() ?? (text.map { var h = FNV1a(); h.combine($0); return h.value } ?? 0),
                     label: "s", detail: text, start: 0, end: 0)
        a.keyCode = keyCode; a.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
        a.target = target; a.fullText = text; a.screenCandidates = screen
        return a
    }
    func mapsRow(_ o: Int, addr: String) -> AXTarget {
        AXTarget(role: "AXRow", subrole: nil, title: nil, identifier: nil,
                 rolePath: "AXWindow/AXTable/AXRow", containerPath: "AXWindow/AXTable",
                 containerRole: "AXTable", containerTitle: "Addrs", ordinal: o,
                 siblingCount: 12, isEnumerable: true, actions: [], url: nil,
                 windowTitle: "Addrs", itemName: addr, texts: [addr])
    }
    var dtPasses: [[Atom]] = []
    let mins = ["24 min","31 min","18 min"]; let typed = ["24","31","18"]
    for i in 0..<3 {
        let ro = ScreenReadout(bundleID: "com.apple.Safari", appName: "Safari",
                               rolePath: "AXWindow/AXWebArea/AXStaticText", role: "AXStaticText", text: mins[i])
        dtPasses.append([
            screenAtom(.click, 201, bundle: "com.apple.Numbers", app: "Numbers", target: mapsRow(i, addr: "a\(i)")),
            screenAtom(.chord, 202, bundle: "com.apple.Numbers", app: "Numbers", keyCode: 8, cmd: true),
            screenAtom(.appSwitch, 203, bundle: "com.apple.Safari", app: "Safari"),
            screenAtom(.chord, 204, bundle: "com.apple.Safari", app: "Safari", keyCode: 9, cmd: true),
            screenAtom(.appSwitch, 205, bundle: "com.apple.Numbers", app: "Numbers"),
            screenAtom(.text, 206, bundle: "com.apple.Numbers", app: "Numbers", text: typed[i], screen: [ro]),
        ])
    }
    let dt = LoopCandidate(patternID: LoopDetector.patternID([201,202,203,204,205,206]),
                           period: dtPasses.last!, completeReps: 3, partialSteps: 1,
                           varyingSteps: [0,5], recentPasses: dtPasses, confidence: 0.9,
                           meanRepSeconds: 15, firstStart: 0, lastEnd: 0)
    let dtPlan = LoopPlan(dt)
    check(dtPlan.advances.contains { if case .value(.fromScreen) = $0.rule { return true }; return false },
          "learned as a fromScreen task")
    let libDT = PatternLibrary(url: tmp)
    libDT.remember(dt, plan: dtPlan, name: "Drive times from office")
    let backDT = PatternLibrary(url: tmp)
    guard let sp = backDT.pattern(dt.patternID), sp.isRunnable else {
        check(false, "reloaded and runnable"); return
    }
    let rc = sp.candidate(liveTail: Array(dtPasses[0].prefix(2)), now: 1)!
    let rp = sp.plan(for: rc)
    check(rp.advances.contains { if case .value(.fromScreen(let a, _, let t, _)) = $0.rule
          { return a == "Safari" && t.pick == .first }; return false },
          "the read-off-Safari step and its convention came back",
          rp.advances.map(\.describe).joined(separator: " | "))
    // And the readout text itself must not be on disk.
    let rawDT = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    check(!rawDT.contains("24 min") && !rawDT.contains("31 min"),
          "the drive times read off screen were never written to disk")

    suite("library: nothing on disk identifies what was done")
    let raw = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    check(!raw.isEmpty, "something was written")
    for leak in ["draft-", ".txt", "secret", "Essay", "canvas", "http", "Today", "Documents", "list view"] {
        check(!raw.lowercased().contains(leak.lowercased()),
              "no \"\(leak)\" in the stored file")
    }
}

// MARK: - The point of no return

func commitSuite() {
    func click(_ title: String) -> Atom {
        let t = AXTarget(role: "AXButton", subrole: nil, title: title,
                         identifier: nil, rolePath: "AXWindow/AXButton",
                         containerPath: "AXWindow", containerRole: "AXWindow",
                         containerTitle: nil, ordinal: 0, siblingCount: 3,
                         isEnumerable: false, actions: ["AXPress"], url: nil,
                         windowTitle: nil, itemName: nil, texts: [title])
        var a = Atom(kind: .click, bundleID: "com.apple.Safari", appName: "Safari",
                     strictKey: 1, varyKey: 0, label: "Click \(title)",
                     detail: nil, start: 0, end: 0)
        a.target = t
        return a
    }
    func chord(_ code: UInt16, cmd: Bool = false, shift: Bool = false) -> Atom {
        var a = Atom(kind: .chord, bundleID: "com.apple.Safari", appName: "Safari",
                     strictKey: 2, varyKey: 0, label: "chord", detail: nil,
                     start: 0, end: 0)
        a.keyCode = code
        var m: UInt64 = 0
        if cmd { m |= CGEventFlags.maskCommand.rawValue }
        if shift { m |= CGEventFlags.maskShift.rawValue }
        a.modifiers = m
        return a
    }
    func plan(_ period: [Atom]) -> LoopPlan {
        LoopPlan(LoopCandidate(patternID: 1, period: period, completeReps: 3,
                               partialSteps: 1, varyingSteps: [],
                               recentPasses: [period], confidence: 0.9,
                               meanRepSeconds: 3, firstStart: 0, lastEnd: 0))
    }

    suite("commit: recognises the irreversible step")
    check(plan([click("Compose"), click("Send")]).commitStep == 1,
          "a Send button", "\(plan([click("Compose"), click("Send")]).commitStep ?? -1)")
    check(plan([click("Open"), click("Save")]).commitStep == 1, "a Save button")
    check(plan([click("New"), chord(0x24, cmd: true)]).commitStep == 1,
          "⌘Return")

    suite("commit: prefers the last one")
    let twoStage = plan([click("Save draft"), click("Next"), click("Submit")])
    check(twoStage.commitStep == 2, "Save draft then Submit stops before Submit",
          "\(twoStage.commitStep ?? -1)")

    suite("commit: does not fire on a substring")
    check(plan([click("Sender name"), click("Next")]).commitStep == nil,
          "\"Sender name\" is not \"Send\"")
    check(plan([click("Open"), click("Close")]).commitStep == nil,
          "an ordinary task has no commit step")
    check(plan([click("Open"), chord(0x24)]).commitStep == nil,
          "a bare Return is not treated as a commit")
}

// MARK: - Number transform (read-and-retype conventions)

func transformSuite() {
    suite("transform: a single number")
    check(NumberTransform.infer(shown: "24 min", typed: "24")
          == NumberTransform(pick: .first, fieldIndex: 0), "\"24 min\" -> 24")
    check(NumberTransform(pick: .first, fieldIndex: 0).apply(to: "31 min") == "31",
          "replayed against \"31 min\" -> 31")

    suite("transform: a traffic range, whichever end the user takes")
    check(NumberTransform.infer(shown: "20–35 min", typed: "20")?.pick == .first,
          "typed the low end")
    check(NumberTransform.infer(shown: "20–35 min", typed: "35")?.pick == .last,
          "typed the high end")
    check(NumberTransform.infer(shown: "20–35 min", typed: "28")?.pick == .midpoint,
          "typed the midpoint")
    // The convention is reproduced against a DIFFERENT range next pass.
    let mid = NumberTransform.infer(shown: "20–35 min", typed: "28")!
    check(mid.apply(to: "10–20 min") == "15", "midpoint convention on 10–20 -> 15",
          mid.apply(to: "10–20 min") ?? "nil")
    let hi = NumberTransform.infer(shown: "20–35 min", typed: "35")!
    check(hi.apply(to: "40–60 min") == "60", "high-end convention on 40–60 -> 60",
          hi.apply(to: "40–60 min") ?? "nil")

    suite("transform: two route options - the top one")
    // Maps lists both routes; the first duration is the top route.
    check(NumberTransform.infer(shown: "24 min", typed: "24") != nil, "reads the top route's time")

    suite("transform: rejects the unrelated")
    check(NumberTransform.infer(shown: "24 min", typed: "99") == nil,
          "a number that isn't there is not a match")
    check(NumberTransform.infer(shown: "no route found", typed: "24") == nil,
          "no number to read -> no transform")
}

// MARK: - The Maps drive-time task (read and retype)

func driveTimeSuite() {
    var clock: UInt64 = 0
    // Office is pinned; origin is not typed. Each pass: copy address from the
    // sheet row, switch to Safari/Maps, paste + Enter, Maps shows "N min",
    // switch back to the sheet, type N into the drive-time cell, next row.
    let addresses = ["12 Elm St", "88 Oak Ave", "5 Pine Rd"]
    let shown     = ["24 min",    "31 min",     "18 min"]
    let typed     = ["24",        "31",         "18"]

    func sheetRow(_ o: Int, addr: String) -> AXTarget {
        AXTarget(role: "AXRow", subrole: nil, title: nil, identifier: nil,
                 rolePath: "AXWindow/AXTable/AXRow", containerPath: "AXWindow/AXTable",
                 containerRole: "AXTable", containerTitle: "Addresses", ordinal: o,
                 siblingCount: 12, isEnumerable: true, actions: [], url: nil,
                 windowTitle: "Addresses", itemName: addr, texts: [addr, ""])
    }
    func atom(_ kind: AtomKind, _ key: UInt64, bundle: String, app: String,
              keyCode: UInt16 = 0, cmd: Bool = false, target: AXTarget? = nil,
              text: String? = nil, screen: [ScreenReadout] = []) -> Atom {
        clock += 1_000_000_000
        var a = Atom(kind: kind, bundleID: bundle, appName: app, strictKey: key,
                     varyKey: target?.varyKey() ?? (text.map { var h = FNV1a(); h.combine($0); return h.value } ?? 0),
                     label: "s", detail: text, start: clock, end: clock)
        a.keyCode = keyCode
        a.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
        a.target = target
        a.fullText = text
        a.screenCandidates = screen
        return a
    }
    let SHEET = "com.apple.Numbers"; let MAPS = "com.apple.Safari"
    func pass(_ i: Int) -> [Atom] {
        // At the moment "N" is typed, Maps' window shows the duration - this is
        // what the capture-time snapshot would have attached.
        let readout = ScreenReadout(bundleID: MAPS, appName: "Safari",
                                    rolePath: "AXWindow/AXWebArea/AXGroup/AXStaticText",
                                    role: "AXStaticText", text: shown[i])
        return [
            atom(.click, 1, bundle: SHEET, app: "Numbers", target: sheetRow(i, addr: addresses[i])),
            atom(.chord, 2, bundle: SHEET, app: "Numbers", keyCode: 8, cmd: true),      // Copy
            atom(.appSwitch, 3, bundle: MAPS, app: "Safari"),                            // to Maps
            atom(.chord, 4, bundle: MAPS, app: "Safari", keyCode: 9, cmd: true),        // Paste
            atom(.chord, 5, bundle: MAPS, app: "Safari", keyCode: 0x24),                // Enter
            atom(.appSwitch, 6, bundle: SHEET, app: "Numbers"),                          // back to sheet
            atom(.text, 7, bundle: SHEET, app: "Numbers", text: typed[i], screen: [readout]),
        ]
    }
    let passes = [pass(0), pass(1), pass(2)]
    let c = LoopCandidate(patternID: 1, period: passes.last!, completeReps: 3,
                          partialSteps: 1, varyingSteps: [0, 6], recentPasses: passes,
                          confidence: 0.9, meanRepSeconds: 15, firstStart: 0, lastEnd: clock)

    suite("drive time: the read-and-retype step is understood")
    let b = BindingInference.binding(forStep: 6, in: passes)
    if case .fromScreen(let app, _, let transform, _) = b {
        check(app == "Safari", "the drive time is read from Safari", app)
        check(transform.pick == .first, "the shown minutes, as typed", "\(transform.pick)")
    } else {
        check(false, "step 7 is a fromScreen binding", "\(b)")
    }

    suite("drive time: the address is read from the sheet row")
    let addr = BindingInference.binding(forStep: 0, in: passes)
    // Step 0 is the click that varies by ordinal - handled as an ordinal
    // advance in the plan, not a value binding. Check the plan instead.
    let plan = LoopPlan(c)
    check(plan.advances.contains { if case .ordinal = $0.rule { return true }; return false },
          "the sheet walks row by row")
    check(plan.advances.contains { if case .value(.fromScreen) = $0.rule { return true }; return false },
          "and the minutes come off the Maps screen",
          plan.advances.map(\.describe).joined(separator: " | "))

    suite("drive time: this is clearly worth automating")
    check(plan.value.isWorthOffering, "offered", plan.value.reasons.joined(separator: "; "))
    check(plan.value.reasons.contains { $0.contains("moves data") }, "credited for moving data")
    check(plan.bound == .known(remaining: 9, total: 12, source: "Addresses"),
          "9 addresses left of 12", "\(plan.bound)")

    suite("drive time: origin typed every pass is a CONSTANT, not a variable")
    // A variant where the user types "office" into an origin box each pass.
    func originPass(_ i: Int) -> [Atom] {
        var p = pass(i)
        p.insert(atom(.text, 8, bundle: MAPS, app: "Safari", text: "office"), at: 4)
        return p
    }
    let op = [originPass(0), originPass(1), originPass(2)]
    let oc = LoopCandidate(patternID: 2, period: op.last!, completeReps: 3, partialSteps: 1,
                           varyingSteps: [0, 7], recentPasses: op, confidence: 0.9,
                           meanRepSeconds: 15, firstStart: 0, lastEnd: clock)
    check(!oc.varyingSteps.contains(4), "the origin step does not vary")
    // Its varyKey is identical every pass, so it is replayed verbatim.
    check(op.allSatisfy { $0[4].varyKey == op[0][4].varyKey }, "\"office\" is constant across passes")

    suite("drive time: mixed signals - minutes one pass, miles another - are refused")
    func mixedPass(_ i: Int, readAs: String) -> [Atom] {
        var p = pass(i)
        let readout = ScreenReadout(bundleID: MAPS, appName: "Safari",
                                    rolePath: "AXWindow/AXWebArea/AXGroup/AXStaticText",
                                    role: "AXStaticText", text: readAs)
        p[6] = atom(.text, 7, bundle: SHEET, app: "Numbers", text: typed[i], screen: [readout])
        return p
    }
    // Pass 3's readout no longer contains the typed number (user read miles).
    let mixed = [pass(0), pass(1), mixedPass(2, readAs: "1.3 mi")]
    let mb = BindingInference.binding(forStep: 6, in: mixed)
    check(!mb.isActionable, "an inconsistent source is not a binding", "\(mb)")
}

// MARK: - Structural identity (values embedded in element titles)

func structuralSuite() {
    var clock: UInt64 = 0
    // A duration element in Maps: same structural position each pass, but the
    // title shows a different time - exactly the trace's "19 min", "17 min"…
    func duration(_ mins: Int) -> AXTarget {
        AXTarget(role: "AXHeading", subrole: nil, title: "\(mins) min",
                 identifier: nil, rolePath: "AXWindow/AXWebArea/AXHeading",
                 containerPath: "AXWindow/AXWebArea", containerRole: "AXWebArea",
                 containerTitle: nil, ordinal: 0, siblingCount: 1, isEnumerable: false,
                 actions: ["AXPress"], url: "https://www.google.com/maps",
                 windowTitle: nil, itemName: nil, texts: ["\(mins) min"])
    }
    // A stable toolbar-style button: same title every pass (identity, not value).
    func button(_ t: String) -> AXTarget {
        AXTarget(role: "AXButton", subrole: nil, title: t, identifier: nil,
                 rolePath: "AXWindow/AXToolbar/AXButton", containerPath: "AXWindow/AXToolbar",
                 containerRole: "AXToolbar", containerTitle: nil, ordinal: 0,
                 siblingCount: 3, isEnumerable: false, actions: ["AXPress"], url: nil,
                 windowTitle: nil, itemName: nil, texts: [t])
    }
    func click(_ target: AXTarget, key: UInt64) -> Atom {
        clock += 500_000_000
        var a = Atom(kind: .click, bundleID: "com.apple.Safari", appName: "Safari",
                     strictKey: target.strictKey(bundleID: "com.apple.Safari", kind: .click),
                     varyKey: target.varyKey(), label: "Click \(target.describe)",
                     detail: nil, start: clock, end: clock)
        a.structuralKey = target.structuralKey(bundleID: "com.apple.Safari", kind: .click)
        a.target = target
        return a
    }
    func chord(_ op: UInt16, _ key: UInt64) -> Atom {
        clock += 500_000_000
        var a = Atom(kind: .chord, bundleID: "com.apple.Safari", appName: "Safari",
                     strictKey: key, varyKey: 0, label: "k", detail: nil, start: clock, end: clock)
        a.keyCode = op; a.modifiers = CGEventFlags.maskCommand.rawValue
        a.structuralKey = key
        return a
    }
    // The motif: click the (changing) duration, Copy, click a stable Back button.
    let mins = [15, 19, 17, 8]
    var passes: [[Atom]] = []
    for m in mins {
        passes.append([click(duration(m), key: 1), chord(8, 2), click(button("Back"), key: 3)])
    }
    let d = LoopDetector()
    var last: LoopCandidate?
    for pass in passes { for a in pass { last = d.ingest(a) } }

    suite("structural: a loop whose value lives in the title is detected")
    check(last != nil, "detected (strict matching alone would miss it)")
    check(last?.stepCount == 3, "3-step period", "\(last?.stepCount ?? -1)")
    check(last?.completeReps == 4, "four passes", "\(last?.completeReps ?? -1)")
    check(last?.varyingSteps.contains(0) == true, "the duration step is the varying value",
          "\(last?.varyingSteps ?? [])")
    check(last?.varyingSteps.contains(2) != true, "the Back button is constant, not a value")

    suite("structural: identity survives across a fresh run (rotation-invariant)")
    // Same task, different times - must be the same patternID.
    func runMins(_ ms: [Int]) -> LoopCandidate? {
        let det = LoopDetector(); var r: LoopCandidate?
        for m in ms { for a in [click(duration(m), key: 1), chord(8, 2), click(button("Back"), key: 3)] { r = det.ingest(a) } }
        return r
    }
    check(runMins([9, 12, 30, 4])?.patternID == last?.patternID,
          "the same task with different drive times is one pattern")

    suite("structural: strict still wins for genuinely distinct buttons")
    // Bold, Italic, Underline in a toolbar, repeated - distinct titles, and
    // they should be three DISTINCT steps, not one structural blob.
    let det2 = LoopDetector(); var r2: LoopCandidate?
    for _ in 0..<3 {
        for t in ["Bold", "Italic", "Underline"] {
            r2 = det2.ingest(click(button(t), key: UInt64(t.count)))
        }
    }
    check(r2?.stepCount == 3, "three distinct toolbar buttons stay three steps",
          "\(r2?.stepCount ?? -1)")
    check(r2?.varyingSteps.isEmpty == true, "none of them is a 'value'", "\(r2?.varyingSteps ?? [])")
}

detectorSuite()
structuralSuite()
commitSuite()
transformSuite()
driveTimeSuite()
librarySuite()
normalizerSuite()
endToEndSuite()
planSuite()
bindingSuite()
noiseSuite()
semanticSuite()
valueSuite()

print("\n\(failures == 0 ? "PASS" : "FAIL") - \(checks - failures)/\(checks) checks\n")
exit(failures == 0 ? 0 : 1)
