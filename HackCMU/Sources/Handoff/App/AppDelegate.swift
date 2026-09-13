import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One library, shared: the pipeline matches against it and the controller
    /// writes to it.
    private let library = PatternLibrary()

    let permissions = PermissionsManager()
    lazy var capture = CaptureCoordinator(library: library)
    lazy var suggestions = SuggestionController(library: library)
    private lazy var replay = ReplayEngine(resolver: capture.resolver, tap: capture.tap)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Redundant with LSUIElement, but explicit: Handoff must never become the
        // active app on its own. Activating would make kAXFocusedApplication
        // return Handoff and corrupt the capture stream.
        NSApp.setActivationPolicy(.accessory)

        // A tap created before the Input Monitoring grant stays permanently
        // dead even once the permission reads as granted, so rebuild on the
        // transition rather than assuming the existing one recovers.
        permissions.onInputMonitoringGranted = { [weak self] in
            guard let self else { return }
            if capture.isRunning { capture.rebuildTap() } else { capture.start() }
        }
        permissions.onAccessibilityGranted = { [weak self] in
            self?.capture.start()
        }

        // The detector reports a candidate on every atom for as long as a loop
        // is running; the controller is what turns that into at most one
        // window. Keeping the two connected here, rather than inside capture,
        // keeps the capture layer unaware that a UI exists at all.
        capture.onCandidate = { [weak self] candidate in
            self?.suggestions.offer(candidate)
        }

        // `./handoff demo` - puts the suggestion window on screen with a
        // hand-built candidate. Performing a real loop on cue takes a minute of
        // deliberate repetition, which is not something to discover is broken
        // in front of an audience.
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.suggestions.showSample()
            }
        }

        // `./handoff replaytest` - see ReplayProbe.
        if let i = CommandLine.arguments.firstIndex(of: "--replaytest") {
            let path = CommandLine.arguments.count > i + 1
                ? CommandLine.arguments[i + 1] : "/tmp/handoff-replaytest.txt"
            let live = CommandLine.arguments.contains("--live")
            // Read off the main actor before dispatching, not inside.
            let resolver = capture.resolver
            let tap = capture.tap
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
                ReplayProbe.run(resolver: resolver, tap: tap, live: live, to: path)
            }
        }

        // `./handoff axdump` - see AXDump. Reads live windows, changes nothing.
        if let i = CommandLine.arguments.firstIndex(of: "--axdump") {
            let path = CommandLine.arguments.count > i + 1
                ? CommandLine.arguments[i + 1] : "/tmp/handoff-axdump.txt"
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
                AXDump.run(resolver: AXResolver(), to: path)
            }
        }

        // Confirmed by the user on the second screen of the suggestion window,
        // never straight off the first one.
        suggestions.onAccept = { [weak self] candidate in
            guard let self, let plan = suggestions.plan else { return }
            replay.panelFrame = suggestions.panelFrame
            var options = ReplayEngine.Options()
            // LOOPY_DRY_RUN=1 resolves and logs every step without posting a
            // single event - the way to watch what it WOULD do.
            options.dryRun = ProcessInfo.processInfo.environment["LOOPY_DRY_RUN"] == "1"
            options.maxPasses = suggestions.effectiveRuns
            options.stopBeforeStep = suggestions.stopBeforeCommit ? plan.commitStep : nil
            replay.run(candidate, plan: plan, options: options) { line in
                NSLog("handoff replay: %@", line)
            } completion: { [weak self] stop in
                let passes: Int
                switch stop {
                case .completed(let n), .interrupted(let n), .failed(_, let n): passes = n
                }
                DispatchQueue.main.async { [weak self] in
                    self?.suggestions.runFinished(stop.isClean ? nil : stop.description,
                                                  passesRun: passes)
                }
            }
        }

        // The dry run behind the confirmation screen: resolves the next pass
        // against what is on screen now and reports it, posting nothing.
        suggestions.onPreview = { [weak self] candidate, plan, done in
            guard let self else { return done([]) }
            var options = ReplayEngine.Options()
            options.dryRun = true
            options.maxPasses = 1
            options.stepDelay = 0
            options.passDelay = 0
            options.stopBeforeStep = suggestions.stopBeforeCommit ? plan.commitStep : nil
            let box = LineBox()
            replay.run(candidate, plan: plan, options: options) { box.add($0) }
                completion: { stop in
                    if !stop.isClean { box.add("⚠︎ \(stop)") }
                    let lines = box.all
                    DispatchQueue.main.async { done(lines) }
                }
        }

        // A task Handoff already knows, recognised from its opening steps.
        capture.onRecognised = { [weak self] pattern, matched, tail in
            self?.suggestions.offerRecognised(pattern, matched: matched, tail: tail)
        }

        capture.statusExtra = { [weak self] in
            guard let self else { return "" }
            let s = suggestions
            return """
            suggest: offered=\(s.offersMade) declined=\(s.declinedAsWorthless) \
            showing=\(s.isShowing) stage=\(s.stage) library=\(library.count)
            lastDecline: \(s.lastDeclineReason ?? "-")
            """
        }

        permissions.refresh()
        permissions.startPolling()

        if permissions.inputMonitoring == .granted {
            capture.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture.stop()
    }
}


/// The replay engine reports on its own queue; this collects without a captured
/// var.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
