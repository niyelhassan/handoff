import AppKit
import Observation
import SwiftUI

/// An automation the user confirmed. Replay does not exist yet; what exists is
/// the record of exactly what was agreed to, which is what replay will consume.
struct AcceptedAutomation: Identifiable, Sendable {
    let id: UInt64
    let title: String
    let steps: Int
    let at: Date
    let candidate: LoopCandidate
}

/// Decides whether a detected loop is worth interrupting someone over, and owns
/// the window that does the interrupting.
///
/// The detector reports a candidate on every atom for as long as a loop is
/// running. Every judgement about whether to SAY so - has this been dismissed,
/// is it too soon, is something already on screen - is here, so that the
/// detector stays a pure function of the stream.
@MainActor
@Observable
final class SuggestionController {

    enum Outcome { case accepted, notNow, never, timedOut }

    /// Quiet periods after a dismissal. "Not now" is a judgement about this
    /// moment, so it expires; "Never" is a judgement about the pattern, so it
    /// does not.
    var notNowQuiet: TimeInterval = 5 * 60
    var acceptedQuiet: TimeInterval = 30 * 60
    var timedOutQuiet: TimeInterval = 3 * 60
    /// An unanswered suggestion is a wrong guess often enough that it should
    /// leave on its own. The timer restarts while the user is still looping,
    /// so it only fires once they have moved on.
    var autoDismissAfter: TimeInterval = 30

    private(set) var live: LoopCandidate?
    private(set) var summary: PatternSummary?
    /// What replaying this would actually involve. Computed locally and always
    /// present - the model never gets a say in the bound or the blockers.
    private(set) var plan: LoopPlan?
    /// Starts as the offline heuristic and is replaced if Claude answers.
    private(set) var understanding: TaskUnderstanding?
    /// The confirmation step. Nothing is replayed until the user has seen what
    /// "the rest" means and said yes to that.
    private(set) var stage: Stage = .suggesting

    enum Stage: Equatable {
        case suggesting, confirming, running, done, rejecting, failed(String)
    }
    private(set) var accepted: [AcceptedAutomation] = []
    private(set) var offersMade = 0
    private(set) var lastOutcome: String?

    // MARK: - What the user can change before anything runs

    /// The name, pre-filled by Handoff and editable. What gets remembered.
    var editedName: String = ""
    /// How many passes to run. Pre-filled from the counted bound, and
    /// overridable - Handoff's count is an inference, and the person watching
    /// their own screen may simply know better.
    var runCount: Int = 1
    /// Stop before the irreversible step. On by default when there is one.
    var stopBeforeCommit: Bool = true
    /// Optional note for why a suggestion was wrong.
    var rejectReason: String = ""

    /// Exactly what the next pass would do, resolved against what is on screen
    /// now, with nothing performed. Populated when the confirmation opens.
    private(set) var preview: [String] = []
    private(set) var previewing = false
    /// Set when this offer came from memory rather than from watching.
    private(set) var recognised: StoredPattern?

    /// The real ceiling for this task, after the commit rule.
    var effectiveRuns: Int {
        guard let plan else { return runCount }
        // A task that ends in something irreversible is prepared ONE at a time.
        // Twenty-seven half-written messages waiting on a human is not help.
        if stopBeforeCommit, plan.commitStep != nil { return 1 }
        return max(1, runCount)
    }
    var maxRuns: Int {
        if case .known(let remaining, _, _) = plan?.bound { return max(1, remaining) }
        return 99
    }

    /// Where replay gets wired in.
    var onAccept: ((LoopCandidate) -> Void)?
    /// Resolves the next pass read-only and reports what it would do.
    var onPreview: ((LoopCandidate, LoopPlan, @escaping ([String]) -> Void) -> Void)?
    let library: PatternLibrary

    private let understander = TaskUnderstander()

    init(library: PatternLibrary = PatternLibrary()) { self.library = library }

    private var panel: SuggestionPanel?
    /// Guards against a slow model answer landing on a later, different loop.
    private var understandingToken = 0
    private var quietUntil: [UInt64: Date] = [:]
    private var silenced: Set<UInt64> = []
    private var dismissTimer: Timer?
    /// Who was in front before Handoff took focus to let the user type.
    private var previousApp: NSRunningApplication?
    private var holdingFocus = false

    var isShowing: Bool { panel != nil }
    /// Where Handoff's own window is, so replay never clicks it.
    var panelFrame: CGRect { panel?.frame ?? .null }

    // MARK: - Intake

    /// An offer made from memory: the opening steps of a task Handoff already
    /// knows. No second and third pass required - the evidence was gathered
    /// last time, and the stored structure is enough to run it.
    func offerRecognised(_ pattern: StoredPattern, matched: Int, tail: [Atom]) {
        guard live == nil, !silenced.contains(pattern.id),
              !library.isRejected(pattern.id) else { return }
        if let until = quietUntil[pattern.id], until > Date() { return }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard pattern.isRunnable,
              let c = pattern.candidate(liveTail: tail, now: now) else {
            // Learned before replay structure was stored: can only be named.
            recognised = pattern
            recognisedNotice = "You've done this before - \(pattern.name)"
            return
        }
        let plan = pattern.plan(for: c)
        recognised = pattern
        recognisedNotice = "You've done this \(pattern.timesSeen)× before - "
            + "finish this one and Handoff can do the rest"
        offer(c, plan: plan, fromMemory: true)
    }

    private(set) var recognisedNotice: String?

    /// How many detections were declined as not worth automating. Surfaced
    /// in the menu so a silent Handoff can be told apart from a broken one.
    private(set) var declinedAsWorthless = 0
    private(set) var lastDeclineReason: String?

    func offer(_ c: LoopCandidate) {
        offer(c, plan: LoopPlan(c), fromMemory: false)
    }

    private func offer(_ c: LoopCandidate, plan incoming: LoopPlan, fromMemory: Bool) {
        if silenced.contains(c.patternID) || library.isRejected(c.patternID) { return }

        // The gate. Repetition alone is not a task - see TaskValue. A task
        // from memory was confirmed by the user once already and skips it.
        // LOOPY_OFFER_EVERYTHING=1 disables it, for probing the pipeline with
        // synthetic input that has no business being automated.
        if !fromMemory, live?.patternID != c.patternID,
           ProcessInfo.processInfo.environment["LOOPY_OFFER_EVERYTHING"] != "1" {
            let value = incoming.value
            if !value.isWorthOffering {
                declinedAsWorthless += 1
                lastDeclineReason = value.vetoes.first
                    ?? String(format: "score %.1f below %.1f", value.score, value.threshold)
                return
            }
        }
        if let until = quietUntil[c.patternID], until > Date() { return }

        if let current = live {
            guard current.patternID == c.patternID else {
                // A second pattern while one is on screen. Swapping the window
                // out from under someone mid-read is worse than missing it.
                return
            }
            // Same loop, another pass: update in place so the count on screen
            // stays true while the user keeps working.
            // Do not rewrite the card out from under someone who is reading
            // the confirmation - only the still-counting first stage updates.
            guard stage == .suggesting else { return }
            live = c
            summary = PatternSummary(c)
            plan = incoming
            // Next runloop pass: SwiftUI has not re-laid out the card yet, so
            // asking for its fitting size right now returns the old height.
            DispatchQueue.main.async { [weak panel] in panel?.refit() }
            armAutoDismiss()
            return
        }

        live = c
        summary = PatternSummary(c)
        stage = .suggesting
        let plan = incoming
        self.plan = plan
        // Shown immediately; the model's version replaces it if it arrives.
        understanding = TaskUnderstander.heuristic(c, plan)

        // Anything the user chose last time for this task wins over defaults.
        let remembered = library.pattern(c.patternID)
        if !fromMemory { recognised = remembered; recognisedNotice = nil }
        editedName = remembered?.name ?? PatternSummary(c).headline
        stopBeforeCommit = remembered?.stopBeforeCommit ?? true
        if case .known(let remaining, _, _) = plan.bound {
            runCount = remembered?.preferredRuns.map { min($0, remaining) } ?? remaining
        } else {
            // No counted list: default to a modest batch the user can edit.
            runCount = remembered?.preferredRuns ?? 5
        }
        rejectReason = ""
        preview = []

        offersMade += 1
        present()
        armAutoDismiss()
        askClaude(c, plan)
    }

    /// Fire-and-forget. The suggestion is already on screen and already useful;
    /// this only ever improves the wording.
    private func askClaude(_ c: LoopCandidate, _ plan: LoopPlan) {
        guard understander.isAvailable else { return }
        understandingToken += 1
        let token = understandingToken
        let id = c.patternID
        understander.understand(c, plan: plan) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.understandingToken,
                      self.live?.patternID == id else { return }
                self.understanding = result
                self.panel?.refit()
            }
        }
    }

    // MARK: - Answers

    /// Answering the suggestion does NOT start anything. It moves to the
    /// confirmation stage, where the user sees the count and the blockers
    /// before a single event is synthesized.
    func accept() {
        guard let c = live, let plan else { return }
        stage = .confirming
        dismissTimer?.invalidate(); dismissTimer = nil   // no time limit on a decision
        takeFocus()
        DispatchQueue.main.async { [weak panel] in panel?.refit() }

        // Resolve the next pass against what is on screen right now and report
        // it, without performing any of it. "Shows exactly what it would do to
        // the next instance before touching anything."
        guard let onPreview else { return }
        previewing = true
        preview = []
        let id = c.patternID
        onPreview(c, plan) { [weak self] lines in
            guard let self, live?.patternID == id else { return }
            previewing = false
            preview = lines
            panel?.refit()
        }
    }

    /// Changing the stop changes which steps would run, so the preview has to
    /// be resolved again - a preview that does not track the setting above it
    /// is worse than none.
    func setStopBeforeCommit(_ on: Bool) {
        guard stopBeforeCommit != on else { return }
        stopBeforeCommit = on
        refreshPreview()
    }

    private func refreshPreview() {
        guard stage == .confirming, let c = live, let plan, let onPreview else { return }
        previewing = true
        preview = []
        let id = c.patternID
        onPreview(c, plan) { [weak self] lines in
            guard let self, live?.patternID == id else { return }
            previewing = false
            preview = lines
            panel?.refit()
        }
    }

    // MARK: - Rejection

    func beginReject() {
        stage = .rejecting
        dismissTimer?.invalidate(); dismissTimer = nil
        takeFocus()
        DispatchQueue.main.async { [weak panel] in panel?.refit() }
    }

    // MARK: - Focus

    /// Becomes the active app so the text fields can actually be typed into.
    ///
    /// Keyboard focus follows the ACTIVE APPLICATION, not the key window, so a
    /// non-activating panel cannot receive a keystroke while another app is in
    /// front - a field on one is decorative. Handoff therefore activates for
    /// exactly the two stages that have fields, and hands focus straight back
    /// afterwards.
    ///
    /// Safe here in a way it is not while watching: the user opened this, and
    /// nothing is being detected from a window they are deliberately typing
    /// into. Handoff's own events are dropped by pid regardless.
    private func takeFocus() {
        guard !holdingFocus else { return }
        holdingFocus = true
        previousApp = NSWorkspace.shared.frontmostApplication
        // A menu-bar-only app is REFUSED activation - measured, not
        // assumed: NSApp.activate() returns with isActive still false and
        // the panel never becomes key, so its text fields can never be
        // typed into. Becoming a regular app for the duration is the
        // documented way out. A Dock icon appears while the dialog is up,
        // which is honest: this IS a dialog, and the user opened it.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        // Next runloop pass: the confirmation's fields do not exist yet at the
        // instant the stage changes.
        DispatchQueue.main.async { [weak panel] in panel?.focusContent() }
    }

    /// Puts the user back where they were. Called before a run starts too, so
    /// replay begins from the same app the task was recorded in.
    private func releaseFocus() {
        guard holdingFocus else { return }
        holdingFocus = false
        // Back to a menu-bar-only app the moment the typing is done, so Handoff
        // stops appearing in the Dock and in Cmd-Tab.
        NSApp.setActivationPolicy(.accessory)
        defer { previousApp = nil }
        guard let previousApp,
              previousApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousApp.activate()
    }

    /// "This isn't the same task." Recorded against the pattern so it is never
    /// offered again, and so the reason is there to learn from.
    func confirmReject() {
        guard let id = live?.patternID else { return }
        library.reject(id, reason: rejectReason.isEmpty ? nil : rejectReason)
        silenced.insert(id)
        finish(.never, id)
    }

    func backToSuggestion() {
        releaseFocus()
        stage = .suggesting
        DispatchQueue.main.async { [weak panel] in panel?.refit() }
        armAutoDismiss()
    }

    /// The real commit, from the confirmation stage only.
    func confirmRun() {
        guard stage == .confirming, let c = live, let plan else { return }
        // Never remember a task under an empty name. A focused text field can
        // hand back "" as focus leaves it for the Run button, and a pattern
        // without a name cannot be recognised OUT LOUD later.
        let name = editedName.trimmingCharacters(in: .whitespaces).isEmpty
            ? (understanding?.name ?? PatternSummary(c).headline) : editedName
        editedName = name
        library.remember(c, plan: plan, name: name)
        library.recordChoices(c.patternID, name: name, runs: runCount,
                              stopBeforeCommit: stopBeforeCommit)
        accepted.insert(AcceptedAutomation(id: c.patternID, title: name,
                                           steps: c.stepCount, at: Date(),
                                           candidate: c), at: 0)
        if accepted.count > 20 { accepted.removeLast(accepted.count - 20) }
        stage = .running
        // Hand focus back BEFORE anything is replayed: the first step expects
        // the app the task was recorded in, not Handoff.
        releaseFocus()
        DispatchQueue.main.async { [weak panel] in panel?.refit() }
        onAccept?(c)
    }

    /// Reported by whoever actually ran the steps.
    func runFinished(_ error: String?, passesRun: Int = 0) {
        guard stage == .running else { return }
        if let id = live?.patternID, passesRun > 0 {
            library.advanceCounters(id, passesRun: passesRun)
        }
        stage = error.map { Stage.failed($0) } ?? .done
        DispatchQueue.main.async { [weak panel] in panel?.refit() }
        let id = live?.patternID
        DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 2.5 : 6)) {
            [weak self] in
            guard let self, let id,
                  self.stage == .done || self.stage.isFailed else { return }
            self.finish(.accepted, id)
        }
    }

    func notNow() { if let id = live?.patternID { finish(.notNow, id) } }

    func never() {
        guard let id = live?.patternID else { return }
        silenced.insert(id)
        finish(.never, id)
    }

    private func finish(_ outcome: Outcome, _ id: UInt64) {
        switch outcome {
        case .accepted: quietUntil[id] = Date().addingTimeInterval(acceptedQuiet)
        case .notNow:   quietUntil[id] = Date().addingTimeInterval(notNowQuiet)
        case .timedOut: quietUntil[id] = Date().addingTimeInterval(timedOutQuiet)
        case .never:    quietUntil.removeValue(forKey: id)
        }
        lastOutcome = "\(outcome) · \(String(format: "%016llx", id).prefix(8))"
        dismissTimer?.invalidate(); dismissTimer = nil
        releaseFocus()
        live = nil
        summary = nil
        plan = nil
        understanding = nil
        recognised = nil
        recognisedNotice = nil
        preview = []
        previewing = false
        rejectReason = ""
        stage = .suggesting
        close()
    }

    private func armAutoDismiss() {
        dismissTimer?.invalidate()
        let t = Timer(timeInterval: autoDismissAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.live?.patternID else { return }
                self.finish(.timedOut, id)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dismissTimer = t
    }

    // MARK: - Window

    private func present() {
        close()
        let p = SuggestionPanel(rootView: SuggestionView(controller: self))
        p.showBottomTrailing()
        panel = p
    }

    private func close() {
        guard let p = panel else { return }
        panel = nil
        p.fadeOutAndClose()
    }

    // MARK: - Demo

    /// Puts a hand-built candidate on screen. Reproducing a real loop takes a
    /// minute of deliberate repetition, which is a bad way to iterate on window
    /// layout - and a worse way to find out the panel is broken.
    var understandingAvailable: Bool { understander.isAvailable }
    var understandingHint: String { understander.unavailableReason }

    func showSample() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        // The address -> drive-time task: copy an address, read the minutes off
        // Maps, type them into the sheet. Exercises the read-and-retype binding
        // and the stop-before nothing (it is read-only, no commit).
        let addrs = ["12 Elm St", "88 Oak Ave", "5 Pine Rd"]
        let mins  = ["24 min", "31 min", "18 min"]
        let typed = ["24", "31", "18"]

        func row(_ o: Int) -> AXTarget {
            AXTarget(role: "AXRow", subrole: nil, title: nil, identifier: nil,
                     rolePath: "AXWindow/AXTable/AXRow", containerPath: "AXWindow/AXTable",
                     containerRole: "AXTable", containerTitle: "Addresses", ordinal: o,
                     siblingCount: 12, isEnumerable: true, actions: [], url: nil,
                     windowTitle: "Addresses", itemName: addrs[o], texts: [addrs[o], ""])
        }
        func pass(_ i: Int) -> [Atom] {
            func a(_ kind: AtomKind, _ key: UInt64, bundle: String, app: String,
                   keyCode: UInt16 = 0, cmd: Bool = false, target: AXTarget? = nil,
                   text: String? = nil, screen: [ScreenReadout] = []) -> Atom {
                var at = Atom(kind: kind, bundleID: bundle, appName: app, strictKey: key,
                              varyKey: target?.varyKey() ?? (text.map { var h = FNV1a(); h.combine($0); return h.value } ?? 0),
                              label: "s", detail: text, start: now, end: now)
                at.keyCode = keyCode; at.modifiers = cmd ? CGEventFlags.maskCommand.rawValue : 0
                at.target = target; at.fullText = text; at.screenCandidates = screen
                return at
            }
            let ro = ScreenReadout(bundleID: "com.apple.Safari", appName: "Safari",
                                   rolePath: "AXWindow/AXWebArea/AXStaticText",
                                   role: "AXStaticText", text: mins[i])
            func lbl(_ at: Atom) -> Atom {
                // Match what the normalizer would have named each step.
                var x = at
                switch x.kind {
                case .appSwitch: x.label = "Switch to \(x.appName)"
                case .chord:     x.label = x.operation?.label ?? "Press a shortcut"
                case .text:      x.label = "Type \(x.fullText?.count ?? 0) characters"
                case .click:     x.label = "Click \(x.target?.describe ?? "")"
                default: break
                }
                return x
            }
            return [
                lbl(a(.click, 1, bundle: "com.apple.Numbers", app: "Numbers", target: row(i))),
                lbl(a(.chord, 2, bundle: "com.apple.Numbers", app: "Numbers", keyCode: 8, cmd: true)),
                lbl(a(.appSwitch, 3, bundle: "com.apple.Safari", app: "Safari")),
                lbl(a(.chord, 4, bundle: "com.apple.Safari", app: "Safari", keyCode: 9, cmd: true)),
                lbl(a(.chord, 5, bundle: "com.apple.Safari", app: "Safari", keyCode: 0x24)),
                lbl(a(.appSwitch, 6, bundle: "com.apple.Numbers", app: "Numbers")),
                lbl(a(.text, 7, bundle: "com.apple.Numbers", app: "Numbers", text: typed[i], screen: [ro])),
            ]
        }
        let passes = [pass(0), pass(1), pass(2)]
        let c = LoopCandidate(patternID: 0xDEAD_BEEF, period: passes.last!, completeReps: 3,
                              partialSteps: 1, varyingSteps: [0, 6], recentPasses: passes,
                              confidence: 0.88, meanRepSeconds: 15, firstStart: now, lastEnd: now)
        silenced.remove(c.patternID)
        quietUntil.removeValue(forKey: c.patternID)
        live = nil
        stage = .suggesting
        offer(c)
        preview = [
            "▸ click item 4 of 12 in Addresses",
            "⌨︎ Copy",
            "⇄ switch to Safari",
            "⌨︎ Paste",
            "⌨︎ Confirm",
            "⇄ switch to Numbers",
            "⌨︎ type \"37\"   (reads the drive time shown in Safari)",
        ]
    }
}


extension SuggestionController.Stage {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
