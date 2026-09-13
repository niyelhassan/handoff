import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Stamped into every event Handoff posts, so the capture layer can tell its own
/// output from the user's. Without this, a replay would be captured, detected
/// as a fresh loop, and would trip its own abort on the first click.
enum ReplayMarker {
    static let value: Int64 = 0x4C_4F_4F_50_59_01   // "LOOPY\u{01}"
}

/// Performs the remaining passes of a loop.
///
/// The core idea, and the reason any of the AX work was worth doing: a step is
/// re-targeted by asking the accessibility tree where its element is NOW, not
/// by replaying the coordinate where it used to be. Scroll the list, move the
/// window, resize it - row 12 is still found, because row 12 is looked up.
///
/// Runs off the main thread. Every step re-checks the abort flag.
final class ReplayEngine: @unchecked Sendable {

    struct Options {
        var stepDelay: TimeInterval = 0.16
        var passDelay: TimeInterval = 0.5
        /// A ceiling that applies even when the list says otherwise. A bad
        /// ordinal inference should waste a few seconds, not an afternoon.
        var maxPasses = 40
        var dryRun = false
        /// A task that hammers a web service (Maps for every address) will draw
        /// rate limits and CAPTCHAs. When a pass reads a value off a web app,
        /// replay paces itself: a longer gap between passes, and a cap after
        /// which it hands back rather than tripping a block the user then has
        /// to clear. Applied automatically when a fromScreen step targets a
        /// browser; see `run`.
        var webPacingSeconds: TimeInterval = 2.5
        var webPassCap = 25
        /// Run every step BEFORE this one and then stop, leaving the
        /// irreversible part to the person. Nil runs the whole pass.
        var stopBeforeStep: Int?
    }

    enum Stop: CustomStringConvertible {
        case completed(passes: Int)
        case interrupted(afterPasses: Int)
        case failed(String, afterPasses: Int)

        var description: String {
            switch self {
            case .completed(let n):   return "completed \(n) pass\(n == 1 ? "" : "es")"
            case .interrupted(let n): return "you took over after \(n) pass\(n == 1 ? "" : "es")"
            case .failed(let why, let n):
                return n == 0 ? why : "\(why) (after \(n) pass\(n == 1 ? "" : "es"))"
            }
        }
        var isClean: Bool { if case .completed = self { return true }; return false }
    }

    private let resolver: AXResolver
    private let tap: EventTapService
    private let queue = DispatchQueue(label: "com.hackcmu.handoff.replay", qos: .userInitiated)
    /// The marker lives on the SOURCE. `CGEventField.eventSourceUserData`
    /// reports the user data of whatever source created an event, so stamping
    /// individual events does not survive posting - which made every
    /// synthesized click read as the user grabbing the wheel.
    private let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.userData = ReplayMarker.value
        return s
    }()

    /// Screen area Handoff's own window occupies, which must never be clicked.
    var panelFrame: CGRect = .null
    /// Rows skipped this run because a value could not be read (ambiguous
    /// address, route still computing). Surfaced in the completion message.
    private var flaggedRows = 0

    init(resolver: AXResolver, tap: EventTapService) {
        self.resolver = resolver
        self.tap = tap
    }

    // MARK: - Driving

    func run(_ c: LoopCandidate, plan: LoopPlan, options: Options = Options(),
             log: @escaping @Sendable (String) -> Void,
             completion: @escaping @Sendable (Stop) -> Void) {

        let passes: Int
        switch plan.bound {
        case .known(let remaining, _, _): passes = min(remaining, options.maxPasses)
        case .exhausted:
            completion(.failed("there is nothing left to do", afterPasses: 0)); return
        case .unknown:
            // No countable list - run exactly what the user asked for.
            passes = options.maxPasses
        }
        guard passes > 0 else {
            completion(.failed("there is nothing left to do", afterPasses: 0)); return
        }

        // If any step reads from a browser, this is a web-scraping loop in
        // disguise: pace it and cap it so it does not get the user CAPTCHA'd.
        var options = options
        let hitsWeb = plan.advances.contains {
            if case .value(.fromScreen(let app, _, _, _)) = $0.rule {
                return app.lowercased().contains("safari") || app.lowercased().contains("chrome")
            }
            return false
        }
        if hitsWeb {
            options.passDelay = max(options.passDelay, options.webPacingSeconds)
            options.maxPasses = min(options.maxPasses, options.webPassCap)
        }
        let cappedPasses = min(passes, options.maxPasses)
        if cappedPasses < passes {
            log("pacing: will do \(cappedPasses) now to avoid a rate limit, "
                + "then you can run it again for the rest")
        }

        queue.async { [self] in
            flaggedRows = 0
            tap.userInterrupted.store(false, ordering: .releasing)
            tap.interruptCause.store(0, ordering: .relaxed)
            if !options.dryRun { tap.replayActive.store(true, ordering: .releasing) }
            defer { tap.replayActive.store(false, ordering: .releasing) }

            var done = 0
            for pass in 1...cappedPasses {
                // Elements resolved during THIS pass, so a later step can read
                // a value off an earlier step's element. Cleared every pass -
                // the whole point is that pass 4 reads pass 4's row.
                var passElements: [Int: AXUIElement] = [:]
                if tap.userInterrupted.load(ordering: .acquiring) {
                    log("interrupted by event type "
                        + "\(tap.interruptCause.load(ordering: .relaxed))")
                    completion(.interrupted(afterPasses: done)); return
                }
                log("pass \(pass) of \(cappedPasses)")
                for (i, atom) in c.period.enumerated() {
                    if let stop = options.stopBeforeStep, i >= stop {
                        log("  ⏸ stopping before step \(stop + 1) - over to you")
                        break
                    }
                    if tap.userInterrupted.load(ordering: .acquiring) {
                        log("interrupted by event type "
                            + "\(tap.interruptCause.load(ordering: .relaxed))")
                        completion(.interrupted(afterPasses: done)); return
                    }
                    if let problem = perform(atom, stepIndex: i, pass: pass,
                                             plan: plan, candidate: c, options: options, log: log,
                                             passElements: &passElements) {
                        completion(.failed(problem, afterPasses: done)); return
                    }
                    Thread.sleep(forTimeInterval: options.stepDelay)
                }
                done += 1
                Thread.sleep(forTimeInterval: options.passDelay)
            }
            if flaggedRows > 0 {
                log("done, but \(flaggedRows) row\(flaggedRows == 1 ? "" : "s") flagged - "
                    + "a value could not be read and was left for you")
            }
            completion(.completed(passes: done))
        }
    }

    private func pidForName(_ name: String) -> Int32? {
        NSWorkspace.shared.runningApplications
            .first { $0.localizedName == name }?.processIdentifier
    }
    private func bundleIDForApp(_ name: String, in c: LoopCandidate) -> String? {
        c.period.first { $0.appName == name }?.bundleID
    }

    // MARK: - One step

    /// Returns a reason to stop, or nil to carry on.
    private func perform(_ atom: Atom, stepIndex: Int, pass: Int,
                         plan: LoopPlan, candidate c: LoopCandidate, options: Options,
                         log: @escaping @Sendable (String) -> Void,
                         passElements: inout [Int: AXUIElement]) -> String? {
        let advance = plan.advances.first { $0.stepIndex == stepIndex }

        switch atom.kind {
        case .chord:
            log("  ⌨︎ \(atom.label)")
            guard !options.dryRun else { return nil }
            key(atom.keyCode, flags: atom.modifiers)
            return nil

        case .text:
            var text = atom.fullText
            switch advance?.binding {
            case .counter(let prefix, let next, let stride)?:
                text = "\(prefix)\(next + stride * (pass - 1))"
            case .fromElement(let step, let textIndex, _)?:
                // Read the value off THIS pass's source element, live. This is
                // the step that turns a macro into an automation.
                guard let src = passElements[step],
                      case let texts = resolver.readableTexts(of: src),
                      textIndex < texts.count else {
                    return "step \(stepIndex + 1) reads a value from step \(step + 1), "
                        + "which is not on screen this time"
                }
                text = texts[textIndex]
            case .fromScreen(let app, let path, let transform, _)?:
                // The read-and-retype step. The value lives on another app's
                // window (Maps' drive time), which is NOT frontmost right now -
                // but AX reads it anyway. Find it, apply the user's convention,
                // type that.
                guard let pid = pidFor(bundleID: bundleIDForApp(app, in: c) ?? "") ?? pidForName(app),
                      let el = resolver.locate(pid: pid, path: path),
                      case let raw = resolver.readableTexts(of: el).first ?? AX.stringValue(el),
                      let shown = raw, let got = transform.apply(to: shown) else {
                    // Maps is asking "did you mean?", or the route has not
                    // computed yet: flag this row and move on rather than
                    // typing a stale value. This is the ambiguous-address case.
                    log("  ⚠︎ step \(stepIndex + 1): could not read \(app) this pass - row flagged, skipping")
                    flaggedRows += 1
                    return nil
                }
                text = got
            case .viaClipboard?:
                // The clipboard already holds it; the recorded keystrokes do
                // the work and nothing needs to be substituted.
                break
            default:
                break
            }
            guard let text, !text.isEmpty else {
                return "step \(stepIndex + 1) types something Handoff never saw"
                    + " (it was entered while the screen was secured)"
            }
            log("  ⌨︎ type \"\(text)\"")
            guard !options.dryRun else { return nil }
            type(text)
            return nil

        case .appSwitch:
            log("  ⇄ switch to \(atom.appName)")
            guard !options.dryRun else { return nil }
            NSRunningApplication
                .runningApplications(withBundleIdentifier: atom.bundleID)
                .first?.activate()
            Thread.sleep(forTimeInterval: 0.25)
            return nil

        case .click, .doubleClick, .contextClick:
            return click(atom, stepIndex: stepIndex, pass: pass,
                         advance: advance, options: options, log: log,
                         passElements: &passElements)

        case .scroll:
            return nil   // never part of a period; here for completeness
        }
    }

    private func click(_ atom: Atom, stepIndex: Int, pass: Int,
                       advance: LoopPlan.Advance?, options: Options,
                       log: @escaping @Sendable (String) -> Void,
                       passElements: inout [Int: AXUIElement]) -> String? {
        guard let target = atom.target else {
            return "step \(stepIndex + 1) is a bare screen position, which Handoff"
                + " will not replay blind"
        }

        // Which item this pass wants.
        var ordinal = target.ordinal
        if case .ordinal(let stride, _)? = advance?.rule {
            ordinal = target.ordinal + stride * pass
        }

        guard let containerPath = target.containerPath,
              let pid = pidFor(bundleID: atom.bundleID) else {
            return "step \(stepIndex + 1)'s window is no longer open"
        }
        guard let container = resolver.locate(pid: pid, path: containerPath,
                                              title: target.containerTitle,
                                              titleHash: target.containerTitleHash) else {
            return "step \(stepIndex + 1)'s \(AXTarget.friendlyRole(target.containerRole ?? "")) "
                + "is no longer on screen"
        }

        let element: AXUIElement?
        if case .clickTemplate(let tpl)? = advance?.rule {
            // A varying click: among the elements at this structural position,
            // click the one whose current title fits the learned shape.
            element = resolver.locateMatching(pid: pid, path: target.rolePath, template: tpl)
            guard element != nil else {
                return "step \(stepIndex + 1): nothing matching \(tpl.describe) is on screen"
            }
        } else if target.isEnumerable {
            element = resolver.item(in: container, role: target.role, ordinal: ordinal)
            guard element != nil else {
                return "there is no item \(ordinal + 1) in "
                    + (target.containerTitle ?? "the list") + " - the list ran out"
            }
        } else {
            // A fixed control: its own path finds it directly.
            element = resolver.locate(pid: pid, path: target.rolePath, title: target.title)
            guard element != nil else {
                return "step \(stepIndex + 1) (\(target.describe)) is no longer on screen"
            }
        }

        if let el = element { passElements[stepIndex] = el }

        // AXPress where the element offers it - no coordinates involved at all.
        if let el = element, target.canPress, AX.actions(el).contains(kAXPressAction as String) {
            log("  ▸ press \(target.isEnumerable ? "item \(ordinal + 1)" : target.describe)")
            guard !options.dryRun else { return nil }
            return AX.perform(el, kAXPressAction as String)
                ? nil : "pressing step \(stepIndex + 1) was refused"
        }

        // A row further down the list than the user ever scrolled has a live
        // rect that is off the bottom of the window. Ask the element to scroll
        // itself into view first - rows in Finder, Gmail and most web tables
        // offer AXScrollToVisible - and only then read where it is.
        if let el = element, AX.actions(el).contains("AXScrollToVisible") {
            if !options.dryRun {
                AX.perform(el, "AXScrollToVisible")
                Thread.sleep(forTimeInterval: 0.12)   // let the scroll settle
            }
        }

        // Otherwise click the element's CURRENT centre. Still not the recorded
        // coordinate: this rect was read from the tree a moment ago.
        guard let el = element, let rect = resolver.frame(of: el) else {
            return "step \(stepIndex + 1) has no position Handoff can click"
        }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        // AX and CGEvent both use top-left origin; NSScreen and NSWindow use
        // bottom-left. Comparing them directly silently comes out true for the
        // wrong half of the screen, so convert once and compare in Cocoa space.
        let cocoa = Self.cocoaPoint(point)
        guard !panelFrame.contains(cocoa) else {
            return "the next click lands underneath Handoff's own window"
        }
        guard NSScreen.screens.contains(where: { $0.frame.contains(cocoa) }) else {
            return "the next click is off-screen"
        }

        log("  ▸ click \(target.isEnumerable ? "item \(ordinal + 1)" : target.describe)"
            + String(format: " at %.0f,%.0f", point.x, point.y))
        guard !options.dryRun else { return nil }

        // A synthesized click goes to whatever window is TOPMOST at that point,
        // which has nothing to do with which element we just looked up. Without
        // raising the target first, a perfectly resolved row gets clicked
        // straight through whatever the user happens to have in front of it -
        // the click lands somewhere else entirely and nothing appears to
        // happen. Raise, then verify, then click.
        if let problem = raise(pid: pid, element: el, point: point) { return problem }

        mouse(point, kind: atom.kind)
        return nil
    }

    /// Brings the element's window to the front and confirms it actually got
    /// there before anything is clicked.
    private func raise(pid: Int32, element: AXUIElement, point: CGPoint) -> String? {
        if let window = windowOf(element) {
            AX.perform(window, kAXRaiseAction as String)
        }
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), !app.isActive {
            app.activate()
        }
        // Activation is asynchronous; clicking before it lands is the same bug
        // as not raising at all.
        for _ in 0..<20 {
            if NSRunningApplication(processIdentifier: pid_t(pid))?.isActive == true {
                Thread.sleep(forTimeInterval: 0.08)   // let the window order settle
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return "could not bring the target window to the front"
    }

    private func windowOf(_ el: AXUIElement) -> AXUIElement? {
        var node = el
        for _ in 0..<20 {
            if AX.role(node) == "AXWindow" { return node }
            guard let p = AX.parent(node) else { return nil }
            node = p
        }
        return nil
    }

    // MARK: - Synthesis

    private func stamp(_ e: CGEvent?) -> CGEvent? {
        e?.setIntegerValueField(.eventSourceUserData, value: ReplayMarker.value)
        return e
    }

    private func key(_ code: UInt16, flags: UInt64) {
        let down = stamp(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true))
        down?.flags = CGEventFlags(rawValue: flags)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        let up = stamp(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false))
        up?.flags = CGEventFlags(rawValue: flags)
        up?.post(tap: .cghidEventTap)
    }

    /// Typed as a unicode string rather than as keycodes: the keycode for a
    /// character depends on the active layout, and Handoff has no business
    /// guessing at the user's.
    private func type(_ text: String) {
        for chunk in text.chunked(16) {
            var units = Array(chunk.utf16)
            let down = stamp(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            let up = stamp(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false))
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
        }
    }

    /// Diagnostics for the probe: did the events actually get built and posted.
    var lastMouseDiagnostic: String = "-"

    private func mouse(_ p: CGPoint, kind: AtomKind) {
        let button: CGMouseButton = kind == .contextClick ? .right : .left
        let downType: CGEventType = kind == .contextClick ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = kind == .contextClick ? .rightMouseUp : .leftMouseUp

        // Moving first makes the target app see a normal pointer arrival;
        // some controls ignore a click that teleports onto them.
        stamp(CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                      mouseCursorPosition: p, mouseButton: .left))?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)

        let clicks = kind == .doubleClick ? 2 : 1
        for n in 1...clicks {
            let down = stamp(CGEvent(mouseEventSource: source, mouseType: downType,
                                     mouseCursorPosition: p, mouseButton: button))
            if n == 1 {
                lastMouseDiagnostic = "source=\(source == nil ? "nil" : "ok")"
                    + " down=\(down == nil ? "nil" : "ok")"
                    + " cursorBefore=\(NSEvent.mouseLocation)"
                    + " front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")"
            }
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
            let up = stamp(CGEvent(mouseEventSource: source, mouseType: upType,
                                   mouseCursorPosition: p, mouseButton: button))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up?.post(tap: .cghidEventTap)
            if n < clicks { Thread.sleep(forTimeInterval: 0.05) }
        }
    }

    /// Top-left screen coordinates (AX, CGEvent) to bottom-left (AppKit).
    /// The primary screen is `screens[0]` and its origin is the shared zero.
    static func cocoaPoint(_ p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    private func pidFor(bundleID: String) -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.processIdentifier
    }
}

private extension String {
    /// keyboardSetUnicodeString is documented for short strings; long runs are
    /// safer sent in pieces than in one call.
    func chunked(_ n: Int) -> [String] {
        guard count > n else { return [self] }
        var out: [String] = []
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: n, limitedBy: endIndex) ?? endIndex
            out.append(String(self[i..<j]))
            i = j
        }
        return out
    }
}
