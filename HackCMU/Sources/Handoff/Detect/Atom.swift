import CoreGraphics
import Foundation

/// One step, in the vocabulary a person would use to describe what they did.
///
/// Atoms are produced at human speed - a few per second at most - so unlike
/// `RawEvent` they are allowed to allocate and hold Strings. Nothing in this
/// file ever runs on the tap thread.
enum AtomKind: UInt8, Sendable {
    case click, doubleClick, contextClick
    case chord        // a key combination or a named key: ⌘S, Tab, Return
    case text         // a run of typed characters
    case scroll
    case appSwitch
}

/// FNV-1a. Deliberately not Swift's `Hasher`: that is seeded per process, and
/// these keys are compared across the detector, the cooldown table, and the
/// debug readout, where a stable printed value is worth more than avalanche
/// quality we do not need.
struct FNV1a {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ b: UInt8) {
        value = (value ^ UInt64(b)) &* 0x0000_0100_0000_01b3
    }
    mutating func combine(_ n: UInt64) {
        withUnsafeBytes(of: n.littleEndian) { for b in $0 { combine(b) } }
    }
    mutating func combine(_ n: Int)    { combine(UInt64(bitPattern: Int64(n))) }
    mutating func combine(_ s: String) { for b in s.utf8 { combine(b) }; combine(0) }
}

struct Atom: Sendable {
    var kind: AtomKind
    var bundleID: String
    var appName: String

    /// Identity. Two atoms are the SAME STEP iff their `strictKey`s match.
    var strictKey: UInt64
    /// A looser identity that ignores the VALUE an element currently shows -
    /// its title. "Click the 19-min result" and "Click the 17-min result" have
    /// different strictKeys (the title differs) but the same structuralKey (same
    /// place in the tree). Used as a fallback so a loop whose steps carry their
    /// changing value in the title - a drive time, a price, a row's address in
    /// a tab name - is still recognised, with the title treated as the value.
    /// Defaults to strictKey; only titled clicks set it apart.
    var structuralKey: UInt64 = 0
    /// The part that is allowed to differ between repetitions - a different
    /// row, a different filename. When a step's `varyKey` changes across reps
    /// but its `strictKey` does not, that step is the loop's parameter.
    var varyKey: UInt64

    /// Short, safe-to-log description: "Click", "Press ⌘C", "Type 7 characters".
    var label: String
    /// Content preview. Shown ONLY in the suggestion window, on the user's own
    /// screen, because confirming an automation you cannot see is not consent.
    /// Never written to the status file and never logged.
    var detail: String?

    var start: UInt64          // CLOCK_UPTIME_RAW ns, same clock as RawEvent
    var end: UInt64
    var x: Float32 = 0
    var y: Float32 = 0
    /// Coalesced presses: holding ↓ for a second is one atom, not forty.
    var repeatCount: Int = 1

    /// Replay payload - what it takes to perform this step again, as opposed
    /// to merely recognise it. Populated per kind; zero elsewhere.
    var keyCode: UInt16 = 0
    var modifiers: UInt64 = 0
    /// The complete typed run, where `detail` is only a 24-character preview.
    /// In-process only: it is never logged, never written to the status file,
    /// and never part of the payload sent for naming. Nil under secure input.
    var fullText: String?

    /// Numbers visible on OTHER apps' windows at the moment this text was typed.
    /// Populated only for short numeric-looking runs, and only when the pass
    /// crossed into another app - the read-and-retype signal. The raw material
    /// for a `fromScreen` binding; never leaves the machine.
    var screenCandidates: [ScreenReadout] = []

    /// The interface element this click landed on, when Accessibility could
    /// name one. Absent means the step fell back to coordinates - which still
    /// detects, but cannot survive the window moving and cannot supply a bound.
    var target: AXTarget?

    /// Whether this step takes part in pattern matching.
    ///
    /// Two kinds of input are highly repetitive and yet say nothing about what
    /// the person is trying to DO:
    ///   - Scrolling. The number of scroll events in "scroll down a bit" varies
    ///     every time, which would break otherwise-identical passes apart.
    ///   - Corrections. Backspace is pressed constantly and never means
    ///     anything automatable; counting it would make "typed it, fixed a
    ///     typo, typed more" look structurally different from "typed it".
    ///
    /// ⌘⌫ is excluded from the exclusion: that is Move to Trash, which is a
    /// real step someone might well want repeated.
    var isSignal: Bool {
        if kind == .scroll { return false }
        if kind == .chord {
            if Self.correctionKeys.contains(keyCode),
               modifiers & Self.commandOrControl == 0 { return false }
            // ⌘⇥ is how a switch is DONE; the switch itself is its own atom.
            if operation?.isSubsumedBySwitch == true { return false }
        }
        return true
    }

    /// The identity used for matching, under a given mode. Structural mode
    /// falls back to the strict key for every atom that never set a distinct
    /// structural one (chords, typing, app switches - already stable).
    func matchKey(structural: Bool) -> UInt64 {
        guard structural else { return strictKey }
        return structuralKey != 0 ? structuralKey : strictKey
    }

    /// The meaning of a chord, where it has one. Nil for typing, clicks, and
    /// chords that are not one of the common operations.
    var operation: SemanticOp? {
        guard kind == .chord else { return nil }
        return SemanticOp.classify(keyCode: keyCode, modifiers: modifiers)
    }

    /// kVK_Delete and kVK_ForwardDelete.
    static let correctionKeys: Set<UInt16> = [0x33, 0x75]
    static let commandOrControl: UInt64 =
        CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
}

// MARK: - Target identity

/// How a click becomes a stable target identity.
///
/// Coordinate banding is a PLACEHOLDER and it is worth being precise about what
/// it cannot do: it cannot tell "the Archive button" from "whatever happens to
/// sit at (712, 430)", so it breaks the moment a window moves. It is here
/// because it needs no Accessibility round-trip and it is enough to exercise
/// the detector end to end.
///
/// PROBE-FINDINGS.md measured the replacement and `AXTarget` now implements it:
/// rolePath + stabilized title + ordinal, with kAXIdentifier as a bonus. This
/// remains the path for every click Accessibility could not resolve.
enum ClickTarget {
    /// Wide enough that a sidebar, a list, and a toolbar land in different
    /// bands, which is the distinction that matters for telling steps apart.
    static let columnBand: Float32 = 64
    /// Roughly a table row. This is the VARYING axis: walking down a list is
    /// the single most common shape of a repeated task, and those repetitions
    /// must still match each other.
    static let rowBand: Float32 = 16

    static func keys(bundleID: String, kind: AtomKind, x: Float32, y: Float32)
        -> (strict: UInt64, vary: UInt64) {
        var s = FNV1a()
        s.combine(UInt64(kind.rawValue))
        s.combine(bundleID)
        s.combine(Int((x / columnBand).rounded(.down)))

        var v = FNV1a()
        v.combine(Int((y / rowBand).rounded(.down)))
        return (s.value, v.value)
    }
}
