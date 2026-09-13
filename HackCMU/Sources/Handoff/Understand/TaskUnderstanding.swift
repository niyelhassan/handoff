import Foundation

/// What Handoff believes the task actually is, in the user's own nouns.
///
/// The detector knows a loop is happening and `LoopPlan` knows how it advances,
/// but neither can say "you're renaming the build artifacts" - that is a
/// judgement about intent, and it is the sentence the user reads before
/// deciding. Claude Fable 5.1 supplies it; the heuristic below supplies a
/// worse-but-instant version so the window is never waiting on the network.
struct TaskUnderstanding: Sendable {
    enum Source: Sendable { case heuristic, model }

    let name: String
    /// What "the rest" concretely means, as a sentence with the number in it.
    let restMeans: String
    /// Anything the model thinks is ambiguous or risky about automating this.
    let concern: String?
    let source: Source

    var isFromModel: Bool { source == .model }
}

/// Builds the prompt, calls the model, and degrades to the heuristic.
///
/// PRIVACY - this is the only part of Handoff that touches the network, and it
/// sends a description of what the user was just doing. Three rules:
///
///   1. It is OFF unless an API key is explicitly configured.
///   2. By DEFAULT it sends structure only: step kinds and operations ("Copy",
///      "Paste", "Switch to Mail"), element roles, container labels like
///      "list view", the counted bound, and each binding as a relation ("step
///      5 reads field 2 of step 1"). Plus the site HOSTNAME - "mail.google.com",
///      never the path - so the task can be named after the app it lives in.
///      No file names, no typed text, no window titles, no full URLs.
///   3. `LOOPY_UNDERSTAND_FULL=1` opts into the richer payload. Nothing is ever
///      sent that the confirmation window does not also show.
///
/// Keystrokes captured under secure input never reach here at all - they carry
/// no detail by construction.
final class TaskUnderstander: @unchecked Sendable {

    private let client: ClaudeClient?
    private let redact: Bool

    var isAvailable: Bool { client != nil }
    var unavailableReason: String {
        client == nil
            ? "Set LOOPY_ANTHROPIC_API_KEY or write ~/.handoff/anthropic-key to let Claude name the task"
            : ""
    }

    init(key: String? = ClaudeClient.discoverKey(),
         redact: Bool = ProcessInfo.processInfo.environment["LOOPY_UNDERSTAND_FULL"] != "1") {
        client = key.map { ClaudeClient(apiKey: $0) }
        self.redact = redact
    }

    /// Instant, offline, and never wrong about facts - just not insightful.
    /// This is what the window shows while the model is still thinking, and
    /// what it keeps if the model cannot be reached.
    static func heuristic(_ c: LoopCandidate, _ plan: LoopPlan) -> TaskUnderstanding {
        let summary = PatternSummary(c)
        return TaskUnderstanding(name: summary.headline,
                                 restMeans: plan.headline,
                                 concern: nil,
                                 source: .heuristic)
    }

    func understand(_ c: LoopCandidate, plan: LoopPlan,
                    completion: @escaping @Sendable (TaskUnderstanding) -> Void) {
        let fallback = Self.heuristic(c, plan)
        guard let client else { completion(fallback); return }

        client.complete(system: Self.system,
                        user: prompt(c, plan),
                        schema: Self.schema) { result in
            switch result {
            case .success(let json):
                guard let name = json["name"] as? String,
                      let rest = json["rest_means"] as? String,
                      !name.isEmpty else {
                    completion(fallback); return
                }
                let concern = (json["concern"] as? String)
                    .flatMap { $0.isEmpty || $0.lowercased() == "none" ? nil : $0 }
                completion(TaskUnderstanding(name: name, restMeans: rest,
                                             concern: concern, source: .model))
            case .failure:
                // Naming is a nicety. A network problem must never cost the
                // user the suggestion itself.
                completion(fallback)
            }
        }
    }

    /// Exactly what `understand` would send, for `./handoff understand` to show.
    /// Inspecting the payload before enabling a feature that leaves the machine
    /// should not require reading the source.
    func debugPrompt(_ c: LoopCandidate, _ plan: LoopPlan) -> String {
        prompt(c, plan)
    }

    // MARK: - Prompt

    private static let system = """
    You name a repetitive task that someone just performed on their Mac, so \
    they can decide whether to let it be automated for them.

    You are shown one pass of the task, as macOS's accessibility layer recorded \
    it, plus what changed between passes. Use the person's own nouns - the file \
    names, app names and page titles you are given. Describe only steps that \
    are listed; never invent one. If what you are shown does not look like a \
    coherent task, say so in `concern` rather than inventing a story that fits.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "rest_means", "concern"],
        "properties": [
            "name": [
                "type": "string",
                "description": "The task, as an imperative phrase of at most 6 "
                    + "words. E.g. 'Rename each build artifact'.",
            ],
            "rest_means": [
                "type": "string",
                "description": "One sentence saying concretely what finishing "
                    + "this task would involve, including how many items are "
                    + "left if that is known.",
            ],
            "concern": [
                "type": ["string", "null"],
                "description": "Anything ambiguous or risky about automating "
                    + "this, or null if nothing stands out. Be specific.",
            ],
        ],
    ]

    private func prompt(_ c: LoopCandidate, _ plan: LoopPlan) -> String {
        var out = ""
        let apps = c.apps
        if !apps.isEmpty { out += "App: \(apps.joined(separator: ", "))\n" }
        if !redact, let w = c.period.compactMap({ $0.target?.windowTitle }).first {
            out += "Window: \(w)\n"
        }
        if let u = c.period.compactMap({ $0.target?.url }).first {
            // The host says "this is Gmail"; the path says which message. Only
            // the first is needed to name a task.
            let host = URL(string: u)?.host ?? ""
            out += redact ? (host.isEmpty ? "" : "Site: \(host)\n") : "Page: \(u)\n"
        }

        out += "\nOne pass of the task:\n"
        for (i, a) in c.period.enumerated() {
            out += "  \(i + 1). \(redact ? Self.strip(a) : a.label)"
            if let d = a.detail, !redact { out += " - typed \"\(d)\"" }
            if let adv = plan.advances.first(where: { $0.stepIndex == i }) {
                out += "  [changes each pass: \(redact ? Self.relation(adv) : adv.describe)]"
            }
            out += "\n"
        }

        out += "\nCompleted \(c.completeReps) times"
        if c.meanRepSeconds >= 0.5 {
            out += String(format: ", about %.0f seconds each", c.meanRepSeconds)
        }
        out += ".\n"

        switch plan.bound {
        case .known(let remaining, let total, let source):
            out += "Handoff counted \(total) items in \(redact ? "the list" : source) "
                + "and thinks \(remaining) are left.\n"
        case .exhausted(let source):
            out += "Handoff thinks the list (\(redact ? "the list" : source)) is finished.\n"
        case .unknown(let reason):
            out += "Handoff cannot tell how many repetitions remain: \(reason).\n"
        }
        if !plan.blockers.isEmpty {
            out += "Handoff cannot safely replay this because: "
                + plan.blockers.joined(separator: "; ") + ".\n"
        }
        return out
    }

    /// A binding as a relation between steps - the shape of the data flow,
    /// with none of the data.
    private static func relation(_ a: LoopPlan.Advance) -> String {
        switch a.rule {
        case .ordinal(let stride, _):
            return abs(stride) == 1 ? "the next item in the list" : "every \(abs(stride))th item"
        case .clickTemplate:
            return "clicks a control whose label changes each pass"
        case .value(let b):
            switch b {
            case .fromElement(let step, let idx, _): return "reads field \(idx + 1) of step \(step + 1)"
            case .fromScreen(let app, _, _, _):     return "reads a number shown in \(app)"
            case .viaClipboard(let step):           return "pastes what step \(step + 1) copied"
            case .counter(_, _, let stride):        return "a number that goes up by \(stride)"
            case .unexplained:                      return "varies, source unknown"
            }
        }
    }

    /// Structure only - no names, no typed text. Operations ARE structure:
    /// "Copy" reveals nothing about what was copied and everything about what
    /// kind of task this is.
    private static func strip(_ a: Atom) -> String {
        switch a.kind {
        case .text:      return "Type text"
        case .appSwitch: return a.appName.isEmpty ? "Switch apps" : "Switch to \(a.appName)"
        case .chord:     return a.operation?.label ?? "Press a shortcut"
        case .scroll:    return "Scroll"
        default:
            guard let t = a.target else { return "Click" }
            let container = t.containerRole.map(AXTarget.friendlyRole) ?? "list"
            return t.isEnumerable
                ? "Click item \(t.ordinal + 1) of \(t.siblingCount) in the \(container)"
                : "Click a \(AXTarget.friendlyRole(t.role))"
        }
    }
}
