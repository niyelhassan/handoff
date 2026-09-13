import Foundation

/// Tasks Handoff has seen before, and what the user said about them.
///
/// PRIVACY - what is written to disk is deliberately STRUCTURE ONLY: step
/// identities, role paths, container names, ordinals, and the shape of each
/// value binding. Never the typed text, never a file or message name, never a
/// URL. A binding is stored as "step 5 reads field 1 of step 1's element",
/// which is enough to replay - because the value is read live at replay time -
/// and is not enough to reconstruct anything the user did.
///
/// Stored at ~/.handoff/patterns.json, 0600.

/// One step, reduced to what replay needs and nothing a person did.
///
/// What is here: how to find the element again (role paths, container label,
/// position), how to press the key again (keycode, modifiers), and which app.
/// What is NOT here, deliberately: the element's text, the file or message
/// name, what was typed, the page URL, the window title, and the container's
/// label - that last one is kept only as a hash, which re-finds the right
/// outline without saying what it was called. A pattern on disk can re-find
/// "the 4th row of the outline that hashes to X"; it cannot say what was in
/// it or what it was named.
struct StoredStep: Codable, Sendable {
    var key: UInt64
    var kind: UInt8
    var label: String
    var keyCode: UInt16
    var modifiers: UInt64
    var bundleID: String
    var appName: String
    // Target structure, present for resolved clicks.
    var role: String?
    var rolePath: String?
    var containerPath: String?
    var containerRole: String?
    /// The container's label as a hash - enough to re-find the right one,
    /// not enough to read it back.
    var containerTitleHash: UInt64?
    var ordinal: Int?
    var siblingCount: Int?
    var isEnumerable: Bool
    var canPress: Bool

    init(_ a: Atom, label: String) {
        key = a.strictKey
        kind = a.kind.rawValue
        self.label = label
        keyCode = a.keyCode
        modifiers = a.modifiers
        bundleID = a.bundleID
        appName = a.appName
        role = a.target?.role
        rolePath = a.target?.rolePath
        containerPath = a.target?.containerPath
        containerRole = a.target?.containerRole
        containerTitleHash = a.target?.containerTitle.map(AXTarget.hash)
            ?? a.target?.containerTitleHash
        ordinal = a.target?.ordinal
        siblingCount = a.target?.siblingCount
        isEnumerable = a.target?.isEnumerable ?? false
        canPress = a.target?.canPress ?? false
    }

    /// Back into an atom - with an empty `texts`, no detail, no full text,
    /// because none of that was kept.
    func atom(now: UInt64) -> Atom {
        var a = Atom(kind: AtomKind(rawValue: kind) ?? .chord, bundleID: bundleID,
                     appName: appName, strictKey: key, varyKey: 0, label: label,
                     detail: nil, start: now, end: now)
        a.keyCode = keyCode
        a.modifiers = modifiers
        if let role, let rolePath {
            a.target = AXTarget(
                role: role, subrole: nil, title: nil, identifier: nil,
                rolePath: rolePath, containerPath: containerPath,
                containerRole: containerRole, containerTitle: nil,
                ordinal: ordinal ?? 0, siblingCount: siblingCount ?? 1,
                isEnumerable: isEnumerable,
                actions: canPress ? ["AXPress"] : [],
                url: nil, windowTitle: nil, itemName: nil, texts: [],
                containerTitleHash: containerTitleHash)
        }
        return a
    }
}

/// A binding as a relation. "Step 5 reads field 2 of step 1" is enough to
/// replay - the field is read live - and says nothing about its contents. The
/// counter keeps its prefix, which is the one piece of typed text that
/// survives; it is needed to continue the sequence and is bounded by design.
struct StoredAdvance: Codable, Sendable {
    var stepIndex: Int
    var rule: String            // "ordinal" | "element" | "clipboard" | "counter"
    var stride: Int?
    var sourceStep: Int?
    var textIndex: Int?
    var counterPrefix: String?
    var counterNext: Int?
    // fromScreen: the app and element to re-read, and the convention.
    var screenApp: String?
    var screenPath: String?
    var pick: String?
    var fieldIndex: Int?
    // clickTemplate: the stable title shape of a varying click.
    var tplPrefix: String?
    var tplSuffix: String?
    var tplShape: String?
    var tplMaskedPrefix: String?

    init?(_ a: LoopPlan.Advance) {
        stepIndex = a.stepIndex
        switch a.rule {
        case .ordinal(let stride, _):
            // The list's name is not stored; the live click supplies it again.
            rule = "ordinal"; self.stride = stride
        case .value(.fromElement(let step, let idx, _)):
            rule = "element"; sourceStep = step; textIndex = idx
        case .value(.viaClipboard(let step)):
            rule = "clipboard"; sourceStep = step
        case .value(.counter(let prefix, let next, let stride)):
            rule = "counter"; counterPrefix = prefix; counterNext = next; self.stride = stride
        case .value(.fromScreen(let app, let path, let transform, _)):
            rule = "screen"; screenApp = app; screenPath = path
            pick = transform.pick.rawValue; fieldIndex = transform.fieldIndex
        case .clickTemplate(let tpl):
            rule = "clickTemplate"; tplPrefix = tpl.prefix; tplSuffix = tpl.suffix
            tplShape = tpl.shape; tplMaskedPrefix = tpl.maskedPrefix
        case .value(.unexplained):
            return nil    // never stored: a task with one of these was not runnable
        }
    }

    func advance(container: String?, labelFor: (Int) -> String) -> LoopPlan.Advance? {
        let label = "Step \(stepIndex + 1)"
        switch rule {
        case "ordinal":
            guard let stride else { return nil }
            return LoopPlan.Advance(stepIndex: stepIndex,
                                    rule: .ordinal(stride: stride, container: container ?? "the list"),
                                    label: label, sourceLabel: nil)
        case "element":
            guard let sourceStep, let textIndex else { return nil }
            return LoopPlan.Advance(stepIndex: stepIndex,
                                    rule: .value(.fromElement(step: sourceStep, textIndex: textIndex,
                                                              sample: "…")),
                                    label: label, sourceLabel: labelFor(sourceStep))
        case "clipboard":
            guard let sourceStep else { return nil }
            return LoopPlan.Advance(stepIndex: stepIndex,
                                    rule: .value(.viaClipboard(copiedAtStep: sourceStep)),
                                    label: label, sourceLabel: labelFor(sourceStep))
        case "counter":
            guard let counterPrefix, let counterNext, let stride else { return nil }
            return LoopPlan.Advance(stepIndex: stepIndex,
                                    rule: .value(.counter(prefix: counterPrefix, next: counterNext,
                                                          stride: stride)),
                                    label: label, sourceLabel: nil)
        case "clickTemplate":
            var tpl = TitleTemplate(prefix: tplPrefix ?? "", suffix: tplSuffix ?? "",
                                    shape: tplShape ?? "")
            tpl.maskedPrefix = tplMaskedPrefix ?? ""
            return LoopPlan.Advance(stepIndex: stepIndex, rule: .clickTemplate(tpl),
                                    label: label, sourceLabel: nil)
        case "screen":
            guard let screenApp, let screenPath, let pick,
                  let p = NumberTransform.Pick(rawValue: pick) else { return nil }
            let t = NumberTransform(pick: p, fieldIndex: fieldIndex ?? 0)
            return LoopPlan.Advance(stepIndex: stepIndex,
                                    rule: .value(.fromScreen(app: screenApp, rolePath: screenPath,
                                                             transform: t, sample: "…")),
                                    label: label, sourceLabel: screenApp)
        default:
            return nil
        }
    }
}

struct StoredPattern: Codable, Sendable {
    var id: UInt64
    /// The user's name for it, if they edited one; otherwise Handoff's.
    var name: String
    /// Identity of each step, in order - the whole basis of recognition.
    var stepKeys: [UInt64]
    /// Safe labels ("Press ⌘C", "Click a row"), for showing a remembered task.
    var stepLabels: [String]
    var timesSeen: Int
    var lastSeen: Date
    /// The user said this is not a real task. Never offered again.
    var rejected: Bool
    var rejectReason: String?
    /// How many passes they chose last time, if they changed it.
    var preferredRuns: Int?
    var stopBeforeCommit: Bool
    /// Enough to run it again. Absent on patterns stored before this existed.
    var steps: [StoredStep]?
    var advances: [StoredAdvance]?
    var commitStep: Int?

    var stepCount: Int { stepKeys.count }
    var isRunnable: Bool { (steps?.count ?? 0) == stepCount && stepCount > 0 }

    // MARK: - Back to life

    /// A candidate for the pass the user has just STARTED.
    ///
    /// The matched opening steps come from the live stream - they carry real,
    /// current targets, including which row was just clicked and how many rows
    /// the list holds today. The rest of the pass comes from memory. Replay
    /// then continues from the item after the one the user is on.
    func candidate(liveTail: [Atom], now: UInt64) -> LoopCandidate? {
        guard let steps, isRunnable else { return nil }
        var period: [Atom] = []
        for (i, step) in steps.enumerated() {
            if i < liveTail.count, liveTail[i].strictKey == step.key {
                period.append(liveTail[i])
            } else {
                period.append(step.atom(now: now))
            }
        }
        return LoopCandidate(
            patternID: id, period: period, completeReps: max(timesSeen, 1),
            partialSteps: liveTail.count, varyingSteps: Set((advances ?? []).map(\.stepIndex)),
            recentPasses: [period], confidence: 0.9, meanRepSeconds: 0,
            firstStart: now, lastEnd: now)
    }

    func plan(for c: LoopCandidate) -> LoopPlan {
        let advances = (self.advances ?? []).compactMap { adv -> LoopPlan.Advance? in
            // Whatever the live click says the list is called, today.
            let container = c.period.indices.contains(adv.stepIndex)
                ? c.period[adv.stepIndex].target?.containerTitle : nil
            return adv.advance(container: container) { i in "step \(i + 1)" }
        }
        // Likewise the commit step's name: from the live element if the user
        // has reached it, otherwise from what the key means.
        var commitLabel: String?
        if let commitStep, c.period.indices.contains(commitStep) {
            let a = c.period[commitStep]
            commitLabel = a.target?.title ?? a.operation?.label ?? "step \(commitStep + 1)"
        }
        return LoopPlan(recognised: c, advances: advances,
                        commitStep: commitStep, commitLabel: commitLabel)
    }
}

/// Remembers patterns across sessions and recognises one from its first steps.
///
/// ENRICH QUEUE for matching; the main actor for edits. Guarded, because those
/// really are different threads.
final class PatternLibrary: @unchecked Sendable {

    /// How much of a known task must be seen before saying so. Two steps is
    /// the floor: one step matching is not evidence of anything, since most
    /// tasks start by clicking something.
    var minPrefixSteps = 2
    /// ...unless the pattern is short, in which case require most of it.
    var minPrefixFraction = 0.4

    private let lock = NSLock()
    private var patterns: [UInt64: StoredPattern] = [:]
    private let url: URL?

    static var defaultURL: URL? {
        guard ProcessInfo.processInfo.environment["LOOPY_NO_PERSIST"] != "1" else {
            return nil
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".handoff", isDirectory: true)
        return dir.appendingPathComponent("patterns.json")
    }

    init(url: URL? = PatternLibrary.defaultURL) {
        self.url = url
        load()
    }

    // MARK: - Recognition

    /// Does the tail of the stream look like the START of something known?
    ///
    /// This is what lets a task learned last Tuesday be offered again after two
    /// steps, rather than making the user perform it twice more from scratch.
    func recognisePrefix(in tail: [Atom]) -> (StoredPattern, matched: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard !tail.isEmpty else { return nil }
        let keys = tail.map(\.strictKey)

        var best: (StoredPattern, Int)?
        for p in patterns.values where !p.rejected && p.stepCount >= 2 {
            let needed = max(minPrefixSteps,
                             Int((Double(p.stepCount) * minPrefixFraction).rounded(.up)))
            // Longest suffix of the stream that is a prefix of this pattern.
            let maxLen = min(keys.count, p.stepCount)
            guard maxLen >= needed else { continue }
            for len in stride(from: maxLen, through: needed, by: -1)
            where Array(keys.suffix(len)) == Array(p.stepKeys.prefix(len)) {
                if best == nil || len > best!.1 { best = (p, len) }
                break
            }
        }
        return best
    }

    // MARK: - Learning

    func remember(_ c: LoopCandidate, plan: LoopPlan, name: String) {
        lock.lock(); defer { lock.unlock() }
        let id = c.patternID
        var p = patterns[id] ?? StoredPattern(
            id: id, name: name, stepKeys: c.period.map(\.strictKey),
            stepLabels: c.period.map { Self.safeLabel($0) },
            timesSeen: 0, lastSeen: Date(), rejected: false,
            rejectReason: nil, preferredRuns: nil, stopBeforeCommit: true)
        p.stepKeys = c.period.map(\.strictKey)
        p.stepLabels = c.period.map { Self.safeLabel($0) }
        p.timesSeen += 1
        p.lastSeen = Date()
        if !name.isEmpty { p.name = name }
        // The structure needed to run it again, refreshed each time so the
        // most recent element paths win.
        p.steps = c.period.map { StoredStep($0, label: Self.safeLabel($0)) }
        p.advances = plan.advances.compactMap(StoredAdvance.init)
        p.commitStep = plan.commitStep
        patterns[id] = p
        save()
    }

    /// After a run, a counter has moved on.
    func advanceCounters(_ id: UInt64, passesRun: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var p = patterns[id], var advances = p.advances, passesRun > 0 else { return }
        for i in advances.indices where advances[i].rule == "counter" {
            if let next = advances[i].counterNext, let stride = advances[i].stride {
                advances[i].counterNext = next + stride * passesRun
            }
        }
        p.advances = advances
        patterns[id] = p
        save()
    }

    func reject(_ id: UInt64, reason: String?) {
        lock.lock(); defer { lock.unlock() }
        var p = patterns[id] ?? StoredPattern(
            id: id, name: "", stepKeys: [], stepLabels: [], timesSeen: 0,
            lastSeen: Date(), rejected: true, rejectReason: reason,
            preferredRuns: nil, stopBeforeCommit: true)
        p.rejected = true
        p.rejectReason = reason
        p.lastSeen = Date()
        patterns[id] = p
        save()
    }

    func recordChoices(_ id: UInt64, name: String?, runs: Int?, stopBeforeCommit: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var p = patterns[id] else { return }
        if let name, !name.isEmpty { p.name = name }
        p.preferredRuns = runs
        p.stopBeforeCommit = stopBeforeCommit
        patterns[id] = p
        save()
    }

    func pattern(_ id: UInt64) -> StoredPattern? {
        lock.lock(); defer { lock.unlock() }
        return patterns[id]
    }

    func isRejected(_ id: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return patterns[id]?.rejected == true
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return patterns.count }

    var all: [StoredPattern] {
        lock.lock(); defer { lock.unlock() }
        return patterns.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Labels reaching disk carry no captured content - no file names, no typed
    /// text, no page titles. "Click item 4 of 31 in a list", not
    /// "Click draft-3.txt".
    private static func safeLabel(_ a: Atom) -> String {
        switch a.kind {
        case .text:      return "Type text"
        case .appSwitch: return "Switch to \(a.appName)"
        case .chord:     return a.label          // "Press ⌘C" - a key, not content
        case .scroll:    return "Scroll"
        default:
            guard let t = a.target else { return "Click" }
            return t.isEnumerable
                ? "Click an item in a \(AXTarget.friendlyRole(t.containerRole ?? "list"))"
                : "Click a \(AXTarget.friendlyRole(t.role))"
        }
    }

    // MARK: - Disk

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        guard let list = try? JSONDecoder().decode([StoredPattern].self, from: data)
        else { return }
        patterns = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    /// Called with the lock held.
    private func save() {
        guard let url else { return }
        let list = Array(patterns.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}
