import AppKit
import ApplicationServices
import Foundation

/// `./handoff replaytest [--live]` - exercises replay targeting against the real
/// Finder window that happens to be open.
///
/// It builds a candidate whose first step clicked a row, fabricates the two
/// passes that would make it a loop, and asks the plan and the engine to work
/// out the rest. Dry by default: every element is located and every coordinate
/// computed from the LIVE tree, but nothing is posted.
///
/// `--live` actually clicks, and is only safe because the steps it replays are
/// row selections - Finder selection changes nothing on disk.
enum ReplayProbe {

    static func run(resolver: AXResolver, tap: EventTapService,
                    live: Bool, to path: String) {
        var out = "=== Handoff replay probe (\(live ? "LIVE" : "dry run")) ===\n\(Date())\n\n"
        func emit(_ s: String) { out += s + "\n" }

        guard AXIsProcessTrusted() else {
            emit("NOT TRUSTED for Accessibility.")
            try? out.write(toFile: path, atomically: true, encoding: .utf8); return
        }
        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            emit("Finder is not running.")
            try? out.write(toFile: path, atomically: true, encoding: .utf8); return
        }

        // Find a row by hit-testing the frontmost Finder window, the same way a
        // real click would have been resolved.
        let pid = finder.processIdentifier
        let appEl = AX.app(pid)
        guard let win = AX.elements(appEl, kAXWindowsAttribute as String).first,
              let origin = AX.point(win, kAXPositionAttribute as String),
              let size = AX.size(win, kAXSizeAttribute as String) else {
            emit("Finder has no usable window.")
            try? out.write(toFile: path, atomically: true, encoding: .utf8); return
        }
        emit("Finder window \"\(AX.stableTitle(win) ?? "-")\" "
             + "\(Int(size.width))x\(Int(size.height)) at \(Int(origin.x)),\(Int(origin.y))")

        var found: AXTarget?
        var y = Float(origin.y + 90)
        while y < Float(origin.y + size.height - 40), found == nil {
            if let t = resolver.resolve(pid: pid, x: Float(origin.x + size.width * 0.33), y: y),
               t.isEnumerable { found = t }
            y += 20
        }
        guard let target = found, target.siblingCount >= 3 else {
            emit("No enumerable row found - open a Finder window with 3+ items in list view.")
            try? out.write(toFile: path, atomically: true, encoding: .utf8); return
        }
        emit("anchor: \(target.describe)  [\(target.role) in \(target.containerRole ?? "-")]")
        emit("container path: \(target.containerPath ?? "-")")
        if let c = resolver.locate(pid: pid, path: target.containerPath ?? "",
                                   title: target.containerTitle) {
            let rows = AX.elements(c, "AXRows")
            emit("located container: \"\(AX.stableTitle(c) ?? "-")\" with \(rows.count) rows")
            for (i, row) in rows.prefix(3).enumerated() {
                emit("  row \(i): \(deepTitle(row) ?? "-")")
            }
        } else {
            emit("located container: ** NOT FOUND **")
        }
        emit("")

        // Fabricate the three passes that a real loop would have produced:
        // the same step, on rows N, N+1, N+2.
        let base = max(0, min(target.ordinal, target.siblingCount - 3))
        func pass(_ ordinal: Int) -> [Atom] {
            var t = target
            t.ordinal = ordinal
            var a = Atom(kind: .click, bundleID: "com.apple.finder", appName: "Finder",
                         strictKey: t.strictKey(bundleID: "com.apple.finder", kind: .click),
                         varyKey: t.varyKey(), label: "Click \(t.describe)",
                         detail: nil, start: 0, end: 0)
            a.target = t
            return [a]
        }
        let passes = [pass(base), pass(base + 1), pass(base + 2)]
        let candidate = LoopCandidate(
            patternID: 1, period: passes.last!, completeReps: 3, partialSteps: 0,
            varyingSteps: [0], recentPasses: passes, confidence: 0.9,
            meanRepSeconds: 1, firstStart: 0, lastEnd: 0)

        let plan = LoopPlan(candidate)
        emit("plan bound   : \(plan.bound)")
        emit("plan advances: \(plan.advances.map(\.describe).joined(separator: " | "))")
        emit("replayable   : \(plan.isReplayable)"
             + (plan.blockers.isEmpty ? "" : "  blockers: \(plan.blockers.joined(separator: "; "))"))
        emit("headline     : \(plan.headline)\n")

        if live, let c = resolver.locate(pid: pid, path: target.containerPath ?? "",
                                         title: target.containerTitle) {
            let before = AX.elements(c, "AXSelectedRows")
                .compactMap { AX.int($0, "AXIndex") }
            emit("selected rows BEFORE replay: \(before)")
        }

        var options = ReplayEngine.Options()
        options.dryRun = !live
        // A probe, not a job. LOOPY_PROBE_PASSES lengthens the run so the
        // interrupt can be tested against it.
        options.maxPasses = Int(ProcessInfo.processInfo
            .environment["LOOPY_PROBE_PASSES"] ?? "") ?? 2
        options.stepDelay = 0.2
        options.passDelay = 0.4

        let engine = ReplayEngine(resolver: resolver, tap: tap)
        // A locked box, not a captured var: the engine's callbacks really do
        // arrive on its own queue.
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
        }
        let log = Log()
        let done = DispatchSemaphore(value: 0)

        engine.run(candidate, plan: plan, options: options) { line in
            log.add(line)
        } completion: { stop in
            log.add("RESULT: \(stop)")
            done.signal()
        }
        if done.wait(timeout: .now() + 30) == .timedOut { emit("TIMED OUT") }
        for l in log.all { emit(l) }
        if live {
            emit("\nmouse diagnostic: \(engine.lastMouseDiagnostic)")
            emit("cursor now: \(NSEvent.mouseLocation)")
            emit("frontmost now: "
                 + (NSWorkspace.shared.frontmostApplication?.localizedName ?? "-"))
        }

        if live {
            // Selection is observable, so the click can be proven to have
            // landed on the row that was aimed at rather than merely posted.
            if let container = resolver.locate(pid: pid,
                                               path: target.containerPath ?? "",
                                               title: target.containerTitle) {
                let selected = AX.elements(container, "AXSelectedRows")
                emit("\nselected rows after replay: \(selected.count)")
                for s in selected.prefix(4) {
                    emit("  index \(AX.int(s, "AXIndex").map(String.init) ?? "-")"
                         + "  \(AX.stableTitle(s) ?? deepTitle(s) ?? "-")")
                }
                // The replayed passes continue PAST the observed ones: the
                // last observed row was base+2, so two more passes land on
                // base+4.
                emit("expected the last click to land on index \(base + 4)")
            }
        }

        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A Finder row carries no title; the filename is on a text field inside.
    private static func deepTitle(_ el: AXUIElement, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        for c in AX.children(el).prefix(8) {
            if let t = AX.stableTitle(c) { return t }
            if let t = deepTitle(c, depth: depth + 1) { return t }
        }
        return nil
    }
}
