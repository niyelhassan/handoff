import Foundation
import Observation
import Synchronization

/// Owns the tap, the enrich queue, and the detection pipeline, and publishes
/// live counters.
///
/// The queue discipline is the whole design: the tap thread only writes to the
/// ring, the enrich queue only drains it and runs normalization + detection,
/// and the main actor only ever receives finished results. Nothing crosses.
@MainActor
@Observable
final class CaptureCoordinator {

    private(set) var eventCount: UInt64 = 0
    private(set) var droppedCount: UInt64 = 0
    private(set) var reenableCount: UInt64 = 0
    private(set) var pendingCount: UInt64 = 0
    private(set) var atomCount: UInt64 = 0
    /// Times the stream has looked like a loop. Not the number of suggestions
    /// shown: the detector reports on every atom while a loop runs, and the
    /// controller collapses that into at most one window.
    private(set) var candidateCount: UInt64 = 0
    private(set) var isRunning = false
    private(set) var tapFailed = false
    /// Last few events, newest first - a debug readout to prove capture works.
    private(set) var recent: [String] = []
    /// Last few normalized steps, newest first. Labels only: an atom's `detail`
    /// holds typed characters and never leaves the suggestion window.
    private(set) var recentAtoms: [String] = []
    private(set) var lastCandidate: String?

    /// Fired on the main actor when the stream looks like a repeated task.
    /// Rate limiting and dismissal policy belong to whoever handles this.
    var onCandidate: ((LoopCandidate) -> Void)?
    /// Extra lines for the status file from layers above capture - what the
    /// suggestion controller decided. Set by the app delegate.
    var statusExtra: (() -> String)?
    /// Fired when the opening steps match a task Handoff already knows.
    var onRecognised: ((StoredPattern, Int, [Atom]) -> Void)?

    /// Exposed so the replay engine can mark its own synthesized events and
    /// watch for the user taking back control. Nothing else should touch it.
    let tap = EventTapService()
    /// Held here rather than inside the pipeline so the enrich queue owns the
    /// only reference: AX calls must never be reachable from the tap thread.
    let resolver = AXResolver()
    private let pipeline: DetectionPipeline

    // Serial: strict ordering matters, and AX enrichment (Phase 2) will run
    // here, where blocking is acceptable. Never MainActor.
    private let enrichQueue = DispatchQueue(
        label: "com.hackcmu.handoff.enrich", qos: .userInitiated)
    private var drainTimer: DispatchSourceTimer?
    private var scratch = ContiguousArray<RawEvent>()

    /// Debug telemetry sink. Lets the build be verified from a terminal, which
    /// matters because Handoff must be launched via `open` (for TCC attribution)
    /// and therefore has no stdout.
    static let statusPath = "/tmp/handoff-status.txt"

    init(library: PatternLibrary = PatternLibrary()) {
        pipeline = DetectionPipeline(resolver: resolver, library: library)
        pipeline.trace = { Self.trace($0) }

        // Wired once, in init rather than start(), so a tap rebuild after a
        // permission grant cannot install a second copy of either handler.
        pipeline.onAtom = { [weak self] atom in
            Self.trace("atom \(atom.kind) app=\(atom.appName) \(atom.label)"
                + " key=\(String(atom.strictKey, radix: 16).prefix(8))"
                + (atom.screenCandidates.isEmpty ? "" : " screenCands=\(atom.screenCandidates.count)"))
            // Corrections and scrolling are dropped here too: a readout that
            // lists steps the detector is ignoring does not describe the
            // detector.
            guard atom.isSignal else { return }
            let line = atom.label
            Task { @MainActor [weak self] in
                guard let self else { return }
                atomCount &+= 1
                recentAtoms = Array(([line] + recentAtoms).prefix(6))
            }
        }
        pipeline.onRecognised = { [weak self] pattern, matched, tail in
            Task { @MainActor [weak self] in
                self?.onRecognised?(pattern, matched, tail)
            }
        }
        pipeline.onCandidate = { [weak self] candidate in
            Task { @MainActor [weak self] in
                guard let self else { return }
                candidateCount &+= 1
                lastCandidate = "\(candidate.stepCount) steps ×\(candidate.completeReps)"
                    + String(format: " %.0f%%", candidate.confidence * 100)
                onCandidate?(candidate)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        tap.start()

        // Poll rather than waking from the callback: an 8ms delay is invisible
        // next to the ~250ms AX budget, and it keeps the tap callback's worst
        // case to a bounded store sequence with no dispatch call at all.
        let t = DispatchSource.makeTimerSource(queue: enrichQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.drain() }
        t.resume()
        drainTimer = t
        isRunning = true
    }

    func stop() {
        drainTimer?.cancel(); drainTimer = nil
        tap.stop()
        isRunning = false
    }

    /// Called after an Input Monitoring grant. A tap created before the grant
    /// stays dead forever, so it must be rebuilt rather than re-enabled.
    func rebuildTap() { tap.restart() }

    // MARK: - enrich queue

    /// LOOPY_TRACE=1 appends every mouse event and every atom to
    /// /tmp/handoff-trace.txt. The status file shows the last few of each, which
    /// is useless when the question is "where did the third click go".
    /// `--trace` rather than an env var: Handoff is launched through `open`,
    /// which does not pass the environment through.
    nonisolated private static let tracing = CommandLine.arguments.contains("--trace")
        || ProcessInfo.processInfo.environment["LOOPY_TRACE"] == "1"
    nonisolated private static let traceHandle: FileHandle? = {
        guard tracing else { return nil }
        let path = "/tmp/handoff-trace.txt"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    nonisolated static func trace(_ line: String) {
        guard let h = traceHandle else { return }
        h.seekToEndOfFile()
        h.write((line + "\n").data(using: .utf8)!)
    }

    private func drain() {
        scratch.removeAll(keepingCapacity: true)
        let n = tap.ring.drain(max: 512, into: &scratch)

        if Self.tracing {
            for e in scratch where e.kind == .mouseDown || e.kind == .mouseUp {
                Self.trace("raw  \(e.kind) pid=\(e.pid) state=\(e.clickState) @\(Int(e.x)),\(Int(e.y)) t=\(e.hostTime / 1_000_000)")
            }
        }
        for e in scratch { pipeline.consume(e) }
        // Unconditional, including on an empty drain: a run of typing ends by
        // the typist pausing, and a pause produces no event to notice it with.
        pipeline.tick(now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))

        let dropped = tap.ring.dropped
        let re = tap.reenables.load(ordering: .relaxed)

        guard n > 0 else {
            let failed = tap.failed.load(ordering: .relaxed)
            Task { @MainActor [weak self] in
                guard let self else { return }
                droppedCount = dropped
                reenableCount = re
                tapFailed = failed
                pendingCount = 0
                // Also on empty drains. The status file is the only way to
                // inspect a running Handoff from a terminal - it is launched via
                // `open` and has no stdout - so a file that only updates while
                // input is arriving reports a stale count for everything that
                // settled after the user stopped typing.
                writeStatus()
            }
            return
        }

        let lines = scratch.suffix(5).reversed().map(Self.describe)
        let pending = tap.ring.pending
        let count = UInt64(n)

        Task { @MainActor [weak self] in
            guard let self else { return }
            eventCount &+= count
            droppedCount = dropped
            reenableCount = re
            pendingCount = pending
            tapFailed = false
            recent = Array((lines + recent).prefix(5))
            writeStatus()
        }
    }

    private var lastStatusWrite: UInt64 = 0

    private func writeStatus() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now &- lastStatusWrite > 500_000_000 else { return }
        lastStatusWrite = now
        let text = """
        running=\(isRunning) tapFailed=\(tapFailed)
        events=\(eventCount) dropped=\(droppedCount) revivals=\(reenableCount) pending=\(pendingCount)
        atoms=\(atomCount) candidates=\(candidateCount) last=\(lastCandidate ?? "-")
        recent:
        \(recent.map { "  " + $0 }.joined(separator: "\n"))
        steps:
        \(recentAtoms.map { "  " + $0 }.joined(separator: "\n"))
        \(statusExtra?() ?? "")
        """
        try? text.write(toFile: Self.statusPath, atomically: true, encoding: .utf8)
    }

    /// Deliberately does NOT render typed characters - this is a debug readout,
    /// and keystroke content never leaves the capture layer.
    private static func describe(_ e: RawEvent) -> String {
        let app = ProcessInfo.processInfo.processIdentifier == e.pid
            ? "self" : String(e.pid)
        switch e.kind {
        case .keyDown:      return "key ↓ code \(e.keyCode) · pid \(app)"
        case .keyUp:        return "key ↑ code \(e.keyCode) · pid \(app)"
        case .flagsChanged: return "modifiers · pid \(app)"
        case .mouseDown:    return "click ↓ ×\(e.clickState) @\(Int(e.x)),\(Int(e.y))"
        case .mouseUp:      return "click ↑ @\(Int(e.x)),\(Int(e.y))"
        case .scroll:       return "scroll \(e.scrollDelta)"
        default:            return "event"
        }
    }
}
