import CoreGraphics
import Foundation

/// What "automate the rest" would actually mean for a given loop.
///
/// Three questions, answered separately because they fail separately:
///   1. How does each varying step advance? (`advances`)
///   2. How many passes are left? (`bound`)
///   3. Can the steps be executed at all? (`blockers`)
///
/// Every one of them is allowed to come back "I don't know". That is the whole
/// point of the type: a loop with no discoverable bound is common, and offering
/// to do "the rest" of an unbounded task is a promise that cannot be kept.
struct LoopPlan: Sendable {

    enum Bound: Sendable, Equatable {
        /// `remaining` more passes, out of `total` items in `source`.
        case known(remaining: Int, total: Int, source: String)
        case exhausted(source: String)
        case unknown(reason: String)
    }

    struct Advance: Sendable {
        enum Rule: Sendable, Equatable {
            /// The next item in a list: ordinals moved by a constant stride.
            case ordinal(stride: Int, container: String)
            /// A value, and where it comes from.
            case value(ValueBinding)
            /// A varying CLICK, found next pass by its stable title shape. The
            /// changing part of the title is incidental (a tab named after the
            /// row); replay clicks whatever matches the template, so no value
            /// needs to be understood.
            case clickTemplate(TitleTemplate)
        }
        let stepIndex: Int
        let rule: Rule
        let label: String
        /// Human name of whatever step a binding reads from.
        let sourceLabel: String?

        var describe: String {
            switch rule {
            case .ordinal(let stride, let container):
                let word = abs(stride) == 1 ? "the next" : "every \(abs(stride))th"
                return "\(label): \(word) item in \(container)"
            case .value(let binding):
                return "\(label): " + binding.describe { _ in sourceLabel ?? "an earlier step" }
            case .clickTemplate(let tpl):
                return "\(label): clicks \(tpl.describe)"
            }
        }
        var isPredictable: Bool {
            switch rule {
            case .ordinal, .clickTemplate: return true
            case .value(let b): return b.isActionable
            }
        }
        var binding: ValueBinding? {
            if case .value(let b) = rule { return b }
            return nil
        }
    }

    let bound: Bound
    let advances: [Advance]
    /// The step that commits something hard to take back - Send, Submit, Save,
    /// Post. Handoff stops before it by default: doing the mechanical work is
    /// helpful, and pressing Send 27 times on the strength of an inference is
    /// not the same kind of act.
    let commitStep: Int?
    let commitLabel: String?
    /// Whether this is worth offering at all. Computed here because it needs
    /// the advances and the commit step; consulted by the controller before a
    /// window is ever shown.
    let value: TaskValue
    /// Reasons this loop cannot be replayed safely. Empty means it can.
    let blockers: [String]
    /// Steps that will be driven by re-reading the element's live position at
    /// replay time rather than by a recorded coordinate.
    let axDrivenSteps: Int
    let totalSteps: Int

    var isReplayable: Bool { blockers.isEmpty }
    var canPredictEveryParameter: Bool { advances.allSatisfy(\.isPredictable) }

    /// One line for the confirmation UI - what the user is being asked to allow.
    var headline: String {
        switch bound {
        case .known(let remaining, _, let source):
            return remaining == 1
                ? "Do this once more, for the last item in \(source)"
                : "Do this \(remaining) more times, for the rest of \(source)"
        case .exhausted(let source):
            return "Nothing left to do - \(source) has no more items"
        case .unknown:
            return "Repeat this - Handoff cannot tell how many are left"
        }
    }

    // MARK: - Inference

    init(_ c: LoopCandidate, supportedApps: Set<String> = AXResolver.supported) {
        totalSteps = c.period.count
        axDrivenSteps = c.period.filter { $0.target != nil }.count

        // --- how each varying step advances ---
        var advances: [Advance] = []
        for i in c.varyingSteps.sorted() where i < c.period.count {
            let series = c.recentPasses.compactMap { $0.indices.contains(i) ? $0[i] : nil }

            // A click that walks a list is described by its ordinal; anything
            // else that varies is a VALUE, and the question is where it came
            // from.
            if let ord = Self.ordinalRule(series) {
                advances.append(Advance(stepIndex: i, rule: ord,
                                        label: "Step \(i + 1)", sourceLabel: nil))
                continue
            }
            // A varying click whose title carries the value (the Maps tab, the
            // duration result): find it next pass by its stable shape. This is
            // a click to re-locate, not a value to reproduce.
            if series.allSatisfy({ $0.kind.isClick }),
               let tpl = TitleTemplate.infer(series.compactMap { $0.target?.title ?? $0.target?.itemName }) {
                advances.append(Advance(stepIndex: i, rule: .clickTemplate(tpl),
                                        label: "Step \(i + 1)", sourceLabel: nil))
                continue
            }
            let binding = BindingInference.binding(forStep: i, in: c.recentPasses)
            var sourceLabel: String?
            switch binding {
            case .fromElement(let step, _, _), .viaClipboard(let step):
                sourceLabel = c.period.indices.contains(step)
                    ? "step \(step + 1)" : nil
            default: break
            }
            advances.append(Advance(stepIndex: i, rule: .value(binding),
                                    label: "Step \(i + 1)", sourceLabel: sourceLabel))
        }
        self.advances = advances

        // --- the point of no return ---
        let commit = Self.findCommitStep(c.period)
        commitStep = commit?.0
        commitLabel = commit?.1

        value = TaskValue(c, advances: advances, commitStep: commit?.0)
        bound = Self.bound(for: c, advances: advances)
        blockers = Self.blockers(for: c, advances: advances, bound: bound,
                                 totalSteps: totalSteps, supportedApps: supportedApps)
    }

    /// A plan for a task REMEMBERED rather than watched. The rules come from
    /// memory - they were inferred from real passes last time - but the bound
    /// is always re-read from whatever is on screen now: the list may have
    /// grown, shrunk, or be a different list entirely.
    init(recognised c: LoopCandidate, advances: [Advance],
         commitStep: Int?, commitLabel: String?,
         supportedApps: Set<String> = AXResolver.supported) {
        totalSteps = c.period.count
        axDrivenSteps = c.period.filter { $0.target != nil }.count
        self.advances = advances
        self.commitStep = commitStep
        self.commitLabel = commitLabel
        value = TaskValue(c, advances: advances, commitStep: commitStep)
        bound = Self.bound(for: c, advances: advances)
        blockers = Self.blockers(for: c, advances: advances, bound: bound,
                                 totalSteps: totalSteps, supportedApps: supportedApps)
    }

    /// Anchored on the ordinal step: the list it walks is the only thing in
    /// the loop that knows how long the loop is.
    private static func bound(for c: LoopCandidate, advances: [Advance]) -> Bound {
        for a in advances {
            guard case .ordinal(let stride, let container) = a.rule, stride != 0,
                  let last = c.period.indices.contains(a.stepIndex)
                    ? c.period[a.stepIndex].target : nil,
                  last.siblingCount > 0
            else { continue }
            let remaining = stride > 0
                ? (last.siblingCount - 1 - last.ordinal) / stride
                : last.ordinal / (-stride)
            return remaining <= 0
                ? .exhausted(source: container)
                : .known(remaining: remaining, total: last.siblingCount, source: container)
        }
        return .unknown(reason: "this task does not walk through a list")
    }

    private static func blockers(for c: LoopCandidate, advances: [Advance], bound: Bound,
                                 totalSteps: Int, supportedApps: Set<String>) -> [String] {
        var blockers: [String] = []
        let apps = Set(c.period.map(\.bundleID)).filter { !$0.isEmpty }
        let unsupported = apps.subtracting(supportedApps)
        if !unsupported.isEmpty {
            let names = Set(c.period.filter { unsupported.contains($0.bundleID) }
                .map(\.appName)).filter { !$0.isEmpty }.sorted()
            blockers.append("Handoff only knows how to drive Finder and Safari"
                + (names.isEmpty ? "" : "; this task uses \(names.joined(separator: ", "))"))
        }
        let unresolved = c.period.filter { $0.kind.isClick && $0.target == nil }
        if !unresolved.isEmpty {
            let n = unresolved.count
            blockers.append("\(n) of \(totalSteps) step\(n == 1 ? " is" : "s are") a bare "
                + "screen position - \(n == 1 ? "it" : "they") would break if a window moved")
        }
        for a in advances where !a.isPredictable {
            blockers.append("\(a.label) changes every pass and Handoff cannot tell where "
                + "the value comes from")
        }
        // An unknown bound is NOT a blocker: the task still replays fine, the
        // user just says how many times in the dialog rather than Handoff
        // counting a list. Only genuinely un-runnable things block.
        return blockers
    }

    /// Words that mean "this is the part that actually happens".
    ///
    /// Matched against a button's accessibility label, so it is the word the
    /// user can see on screen - not a guess about what the app does.
    static let commitWords = [
        "send", "submit", "post", "publish", "save", "confirm", "pay",
        "order", "book", "delete", "remove", "archive", "reply", "share",
    ]

    /// The LAST step that looks like a commit. Last rather than first: a task
    /// may click "Save" on a draft halfway through and "Send" at the end, and
    /// the one worth stopping before is the end.
    private static func findCommitStep(_ period: [Atom]) -> (Int, String)? {
        var found: (Int, String)?
        for (i, a) in period.enumerated() {
            if a.kind == .chord {
                if a.operation?.isCommit == true { found = (i, a.label) }
                // ⇧⌘D is Mail's own Send.
                let cmdShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
                if a.modifiers & cmdShift == cmdShift, a.keyCode == 0x02 { found = (i, "Send") }
                continue
            }
            guard a.kind.isClick, let t = a.target,
                  let title = (t.title ?? t.itemName)?.lowercased() else { continue }
            // Whole-word-ish: "Send" matches, "Sender" and "Resend all" do not
            // get to hijack this on a substring.
            let words = title.split(whereSeparator: { !$0.isLetter }).map(String.init)
            if words.contains(where: { commitWords.contains($0) }) {
                found = (i, t.title ?? t.itemName ?? "that button")
            }
        }
        return found
    }

    /// A list walk: constant stride between the ordinals of the same element.
    private static func ordinalRule(_ series: [Atom]) -> Advance.Rule? {
        let ordinals = series.compactMap { $0.target?.ordinal }
        guard ordinals.count == series.count, ordinals.count >= 2 else { return nil }
        let steps = zip(ordinals, ordinals.dropFirst()).map { $1 - $0 }
        guard let first = steps.first, first != 0,
              steps.allSatisfy({ $0 == first }) else { return nil }
        let container = series.last?.target?.containerTitle
            ?? series.last?.target?.containerRole.map(AXTarget.friendlyRole)
            ?? "the list"
        return .ordinal(stride: first, container: container)
    }
}

extension AtomKind {
    var isClick: Bool {
        self == .click || self == .doubleClick || self == .contextClick
    }
}
