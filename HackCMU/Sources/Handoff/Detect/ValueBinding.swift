import CoreGraphics
import Foundation

/// Where a value that changes every pass actually comes from.
///
/// This is the difference between a macro and an automation. A macro replays
/// "type the letters i-n-v-o-i-c-e". An automation knows that the text typed
/// into the calendar was the title of the assignment row that was opened two
/// steps earlier - and so on the next pass it reads the NEXT assignment's title
/// instead of typing the old one again.
///
/// Inferred only from evidence across passes, never assumed: a relationship
/// that does not hold on every observed pass is not a relationship.
enum ValueBinding: Sendable, Equatable {

    /// Read off an element touched earlier in the same pass.
    /// `textIndex` indexes `AXTarget.texts`, whose order is stable.
    case fromElement(step: Int, textIndex: Int, sample: String)

    /// Read off ANOTHER app's window and retyped - never through the clipboard.
    /// The Maps drive-time case: paste an address, read "24 min", type 24. The
    /// value is found again at replay time by role path in that app, and the
    /// transform reproduces the user's convention (top route, range midpoint…).
    case fromScreen(app: String, rolePath: String, transform: NumberTransform, sample: String)

    /// Arrived through the clipboard: something was copied earlier in the pass
    /// and pasted here. Nothing needs to be understood to replay it - the
    /// clipboard carries the value - but saying so out loud is what lets a
    /// person recognise their own task.
    case viaClipboard(copiedAtStep: Int)

    /// A trailing number that advances by a constant.
    case counter(prefix: String, next: Int, stride: Int)

    /// It changes, and nothing explains how.
    case unexplained(samples: [String])

    var isActionable: Bool {
        if case .unexplained = self { return false }
        return true
    }

    var movesData: Bool {
        switch self {
        case .fromElement, .fromScreen, .viaClipboard: return true
        default: return false
        }
    }

    func describe(stepLabel: (Int) -> String) -> String {
        switch self {
        case .fromElement(let step, _, let sample):
            return "takes it from \(stepLabel(step)) (e.g. \u{201C}\(sample)\u{201D})"
        case .fromScreen(let app, _, let transform, let sample):
            return "reads \(transform.describe) in \(app) (e.g. \u{201C}\(sample)\u{201D})"
        case .viaClipboard(let step):
            return "pastes what \(stepLabel(step)) copied"
        case .counter(let prefix, let next, _):
            return "types \u{201C}\(prefix)\(next)\u{201D} next"
        case .unexplained(let samples):
            let shown = samples.suffix(3).joined(separator: ", ")
            return "changes every pass (\(shown)) and Handoff cannot tell how"
        }
    }
}

/// Works out the bindings for a candidate's varying steps.
enum BindingInference {

    /// `passes` are complete passes, oldest first.
    static func binding(forStep i: Int, in passes: [[Atom]]) -> ValueBinding {
        let series = passes.compactMap { $0.indices.contains(i) ? $0[i] : nil }
        guard series.count >= 2 else { return .unexplained(samples: []) }

        if let b = fromElement(step: i, series: series, passes: passes) { return b }
        if let b = viaClipboard(step: i, passes: passes) { return b }
        if let b = fromScreen(series: series) { return b }
        if let b = counter(series: series) { return b }

        return .unexplained(samples: series.compactMap {
            $0.detail ?? $0.target?.itemName ?? $0.target?.title
        })
    }

    // MARK: - Data read off the screen

    /// Looks for a value that appears, in every pass, at the same position of
    /// the same earlier step's element.
    ///
    /// Requiring the SAME (step, textIndex) on every pass is what keeps this
    /// honest. A one-pass coincidence - the typed word happening to appear
    /// somewhere on screen - cannot survive three passes at a fixed position.
    private static func fromElement(step i: Int, series: [Atom],
                                    passes: [[Atom]]) -> ValueBinding? {
        let typed = series.map { $0.fullText ?? $0.detail ?? "" }
        guard typed.allSatisfy({ !$0.isEmpty }) else { return nil }

        // Candidate relationships from the first pass, then tested on the rest.
        guard let first = passes.first, first.indices.contains(i) else { return nil }
        var candidates: [(step: Int, textIndex: Int)] = []
        for s in 0..<i {
            guard let target = first[s].target else { continue }
            for (k, text) in target.texts.enumerated()
            where matches(typed: typed[0], source: text) {
                candidates.append((s, k))
            }
        }

        for c in candidates {
            var holds = true
            for (p, pass) in passes.enumerated() {
                guard pass.indices.contains(c.step),
                      let t = pass[c.step].target,
                      c.textIndex < t.texts.count,
                      matches(typed: typed[p], source: t.texts[c.textIndex])
                else { holds = false; break }
            }
            if holds {
                return .fromElement(step: c.step, textIndex: c.textIndex,
                                    sample: typed[typed.count - 1])
            }
        }
        return nil
    }

    /// Exact, or the typed value is a leading chunk of the source. Typing the
    /// first line of a multi-line cell is still copying it; typing three
    /// characters that happen to occur inside it is not, hence the floor.
    private static func matches(typed: String, source: String) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, !s.isEmpty else { return false }
        if t == s { return true }
        return s.hasPrefix(t) && Double(t.count) / Double(s.count) >= 0.5
    }

    // MARK: - Read off another screen

    /// A value that, on every pass, is what the SAME element on another app's
    /// window would yield under ONE convention. Requiring the same role path
    /// and the same transform across all passes is what stops a stray number
    /// on screen from being mistaken for the source.
    private static func fromScreen(series: [Atom]) -> ValueBinding? {
        let typed = series.map { $0.fullText ?? $0.detail ?? "" }
        guard typed.allSatisfy({ !$0.isEmpty }),
              series.allSatisfy({ !$0.screenCandidates.isEmpty }) else { return nil }

        // Candidate (app, path) pairs from the first pass, tested on the rest.
        guard let first = series.first else { return nil }
        for cand in first.screenCandidates {
            guard let t0 = NumberTransform.infer(shown: cand.text, typed: typed[0]) else { continue }
            var holds = true
            for (p, atom) in series.enumerated() {
                guard let match = atom.screenCandidates.first(where: {
                    $0.bundleID == cand.bundleID && $0.rolePath == cand.rolePath
                }), let got = t0.apply(to: match.text),
                   NumberTransform.numbers(in: got).first.map({ approxEq($0, typed[p]) }) ?? (got == typed[p])
                else { holds = false; break }
            }
            if holds {
                return .fromScreen(app: cand.appName, rolePath: cand.rolePath,
                                   transform: t0, sample: typed[typed.count - 1])
            }
        }
        return nil
    }

    private static func approxEq(_ n: Double, _ typed: String) -> Bool {
        guard let t = Double(typed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return abs(n - t) < 0.5
    }

    // MARK: - Clipboard

    /// A paste in this step with a copy earlier in the same pass.
    private static func viaClipboard(step i: Int, passes: [[Atom]]) -> ValueBinding? {
        guard let first = passes.first, first.indices.contains(i),
              isChord(first[i], "v") else { return nil }
        for s in stride(from: i - 1, through: 0, by: -1) where isChord(first[s], "c") {
            // Must hold on every pass, same position.
            let consistent = passes.allSatisfy {
                $0.indices.contains(s) && $0.indices.contains(i)
                    && isChord($0[s], "c") && isChord($0[i], "v")
            }
            if consistent { return .viaClipboard(copiedAtStep: s) }
        }
        return nil
    }

    private static func isChord(_ a: Atom, _ letter: String) -> Bool {
        letter == "c" ? a.operation == .copy || a.operation == .cut
                      : a.operation == .paste
    }

    // MARK: - Counters

    private static func counter(series: [Atom]) -> ValueBinding? {
        let texts = series.compactMap { $0.fullText ?? $0.detail }
        guard texts.count == series.count, texts.count >= 2,
              !texts.contains(where: { $0.hasSuffix("\u{2026}") }) else { return nil }
        let split = texts.map(splitTrailingNumber)
        guard split.allSatisfy({ $0.number != nil }),
              let prefix = split.first?.prefix,
              split.allSatisfy({ $0.prefix == prefix }) else { return nil }
        let nums = split.compactMap(\.number)
        let steps = zip(nums, nums.dropFirst()).map { $1 - $0 }
        guard let d = steps.first, d != 0, steps.allSatisfy({ $0 == d }),
              let last = nums.last else { return nil }
        return .counter(prefix: prefix, next: last + d, stride: d)
    }

    static func splitTrailingNumber(_ s: String) -> (prefix: String, number: Int?) {
        var digits = ""
        var idx = s.endIndex
        while idx > s.startIndex {
            let before = s.index(before: idx)
            guard s[before].isNumber else { break }
            digits.insert(s[before], at: digits.startIndex)
            idx = before
        }
        guard !digits.isEmpty, let n = Int(digits) else { return (s, nil) }
        return (String(s[s.startIndex..<idx]), n)
    }
}
