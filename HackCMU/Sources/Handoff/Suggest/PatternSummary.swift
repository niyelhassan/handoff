import Foundation

/// The suggestion Handoff arrives at the dialog already holding.
///
/// The window never asks the user what they were doing - it states what Handoff
/// believes they were doing and waits to be confirmed or corrected. Everything
/// needed for that claim is computed here.
struct PatternSummary: Sendable {

    struct Step: Sendable, Identifiable {
        let id: Int
        let text: String
        let detail: String?
        /// True when this step's value changed between repetitions: the loop's
        /// parameter, and the part a replay has to be told how to advance.
        let varies: Bool
    }

    /// The proposed automation, as a name: "Click → ⌘C → Mail → ⌘V".
    let title: String
    /// The claim being made: "Repeating a 4-step task in Finder and Mail".
    let headline: String
    /// The evidence for it: "3 times so far · about 6s each".
    let evidence: String
    let steps: [Step]
    /// Plain-English note about the varying steps, or nil when nothing varies.
    let parameterNote: String?
    let confidence: Double

    init(_ c: LoopCandidate) {
        confidence = c.confidence

        steps = c.period.enumerated().map { i, a in
            Step(id: i, text: a.label, detail: a.detail,
                 varies: c.varyingSteps.contains(i))
        }

        let shorts = c.period.map(Self.shortLabel)
        let shown = shorts.prefix(4).joined(separator: " → ")
        title = shorts.count > 4 ? shown + " → …" : shown

        let apps = c.apps
        let where_: String
        switch apps.count {
        case 0:  where_ = ""
        case 1:  where_ = " in \(apps[0])"
        case 2:  where_ = " across \(apps[0]) and \(apps[1])"
        default: where_ = " across \(apps.count) apps"
        }
        headline = "Repeating a \(c.stepCount)-step task\(where_)"

        let times = "\(c.completeReps) times so far"
        evidence = c.meanRepSeconds >= 0.4
            ? "\(times) · about \(Self.duration(c.meanRepSeconds)) each"
            : times

        // Naming the varying step is the difference between "replay this" and
        // "replay this for each row", and the user is the only one who can
        // confirm which was meant.
        let varyingNames = c.varyingSteps.sorted().compactMap { i -> String? in
            guard i < c.period.count else { return nil }
            return Self.shortLabel(c.period[i]).lowercased()
        }
        switch varyingNames.count {
        case 0:  parameterNote = nil
        case 1:  parameterNote = "Step \(c.varyingSteps.sorted()[0] + 1) "
                    + "(\(varyingNames[0])) changes every pass."
        default: parameterNote = "\(varyingNames.count) steps change every pass."
        }
    }

    private static func shortLabel(_ a: Atom) -> String {
        switch a.kind {
        case .click:        return "Click"
        case .doubleClick:  return "Double-click"
        case .contextClick: return "Right-click"
        case .text:         return "Type"
        case .scroll:       return "Scroll"
        case .appSwitch:    return a.appName.isEmpty ? "Switch app" : a.appName
        case .chord:
            if let op = a.operation { return op.label }
            // "Press ⌘F5" -> "⌘F5"; the verb is noise in a chain of four.
            return a.label.hasPrefix("Press ") ? String(a.label.dropFirst(6)) : a.label
        }
    }

    private static func duration(_ s: Double) -> String {
        if s < 60 { return "\(Int(s.rounded()))s" }
        let m = Int((s / 60).rounded())
        return "\(m) min"
    }
}
