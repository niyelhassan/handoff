import Foundation

/// Whether automating this would be worth anything.
///
/// Repetition is necessary and nowhere near sufficient. Typing is repetitive;
/// so is pressing the same key. Neither is a task, and offering to automate
/// them trains the user to ignore the window. What makes a loop worth
/// interrupting someone over is that it MOVES DATA, CROSSES APPS, WALKS A
/// LIST, or ENDS IN SOMETHING - ideally several of those at once.
struct TaskValue: Sendable {
    let score: Double
    /// Why it is worth it, in the order they were found.
    let reasons: [String]
    /// Hard reasons it is not, regardless of score.
    let vetoes: [String]

    var isWorthOffering: Bool { vetoes.isEmpty && score >= threshold }
    let threshold = 1.0

    init(_ c: LoopCandidate, advances: [LoopPlan.Advance], commitStep: Int?) {
        var score = 0.0
        var reasons: [String] = []
        var vetoes: [String] = []
        let period = c.period

        let clicks = period.filter { $0.kind.isClick }
        let switches = period.filter { $0.kind == .appSwitch }
        let apps = Set(period.map(\.bundleID).filter { !$0.isEmpty })

        // --- what makes it worth it ---
        let movesData = period.contains { $0.operation?.movesData == true }
            || advances.contains { if case .value(.fromElement) = $0.rule { return true }; return false }
        if movesData {
            score += 2.0
            reasons.append("moves data from one place to another")
        }
        if apps.count >= 2 || !switches.isEmpty {
            score += 1.5
            reasons.append("crosses between apps")
        }
        if advances.contains(where: { if case .ordinal = $0.rule { return true }; return false }) {
            score += 1.5
            reasons.append("walks through a list")
        }
        if commitStep != nil {
            score += 0.5
            reasons.append("ends in an action")
        }
        let categories = Set(period.map { a -> String in
            if let op = a.operation { return "op:\(op.rawValue)" }
            return "kind:\(a.kind.rawValue)"
        })
        if categories.count >= 3 {
            score += 0.5
            reasons.append("has \(categories.count) different kinds of step")
        }
        if clicks.filter({ $0.target != nil && !($0.target!.isEnumerable) }).count >= 2 {
            score += 0.5
            reasons.append("drives specific controls")
        }
        // A multi-step sequence repeated verbatim is a task in its own right,
        // even when Handoff cannot yet see data moving through it.
        if period.count >= 3, !clicks.isEmpty {
            score += 1.0
            reasons.append("a \(period.count)-step sequence, repeated")
        }

        // --- what rules it out ---
        if period.allSatisfy({ $0.kind == .text }) {
            vetoes.append("this is just typing")
        }
        if Set(period.map(\.strictKey)).count == 1,
           !advances.contains(where: { if case .ordinal = $0.rule { return true }; return false }) {
            vetoes.append("this is the same thing over and over")
        }
        // Deliberately NOT vetoed for lacking a click: a keyboard-driven
        // task (Tab between fields, ⌘C, ⌘V, ⌘↩) is real and automatable. The
        // two vetoes above - pure typing, one thing over and over - are the
        // only genuinely worthless shapes.

        self.score = score
        self.reasons = reasons
        self.vetoes = vetoes
    }
}
