import Foundation

/// A repeated task the detector is confident enough to interrupt the user over.
struct LoopCandidate: Sendable, Identifiable {
    /// Rotation-invariant identity of the pattern itself. Survives the user
    /// doing the loop again an hour later, which is what makes "never suggest
    /// this again" mean anything.
    let patternID: UInt64
    var id: UInt64 { patternID }

    /// The most recent COMPLETE repetition. This is the thing we are offering
    /// to replay, so it must be a whole pass, not the partial one in flight.
    let period: [Atom]
    let completeReps: Int
    /// How far into the next repetition the user already is. Zero when the
    /// last pass happened to land exactly on the period boundary.
    let partialSteps: Int
    /// Indices into `period` whose value changed between repetitions: the
    /// loop's parameters.
    let varyingSteps: Set<Int>
    /// The last few complete passes, oldest first. Knowing WHICH steps vary is
    /// not enough to continue a loop - working out that the row went 2, 3, 4
    /// and the next one is 5 needs the actual sequence of values.
    let recentPasses: [[Atom]]
    let confidence: Double
    let meanRepSeconds: Double
    let firstStart: UInt64
    let lastEnd: UInt64
    /// Stray steps that were skipped to make the passes line up - a mis-click,
    /// a dismissed popup. Zero for an exact match.
    var strayStepsIgnored: Int = 0

    var stepCount: Int { period.count }
    var apps: [String] {
        var seen = Set<String>(), out = [String]()
        for a in period where !a.appName.isEmpty {
            if seen.insert(a.appName).inserted { out.append(a.appName) }
        }
        return out
    }
}

/// Finds the shortest repeating suffix of the atom stream.
///
/// ENRICH QUEUE ONLY.
///
/// The shape being looked for: the last `m` atoms each match the atom `p`
/// positions before them. That single condition covers both "ABC ABC AB" and
/// "A A A A", and the smallest `p` that satisfies it is the true period -
/// checking small periods first is what stops a 3-step loop from being reported
/// as a 6-step one.
final class LoopDetector {

    /// Longest task we will try to recognize. The cost is O(maxPeriod × buffer)
    /// per atom, which at human input rates is nothing.
    var maxPeriod = 16
    var bufferCapacity = 512
    /// Two full passes plus a step into the third. Two passes alone is a
    /// coincidence often enough to be annoying; waiting for three full passes
    /// means offering to automate the work right after the user finished it.
    var minCompleteReps = 2
    /// A single-step loop ("click each checkbox") is real but far more easily
    /// faked by idle clicking, so it has to clear a higher bar.
    var minRepsForUnitPeriod = 3
    /// Consecutive steps further apart than this are not one task. Bounds the
    /// case where someone does something twice, goes to lunch, does it again.
    var maxGapNS: UInt64 = 25_000_000_000
    var maxSpanNS: UInt64 = 900_000_000_000
    var minConfidence = 0.4

    private(set) var atoms: [Atom] = []      // signal atoms only

    var count: Int { atoms.count }

    func reset() { atoms.removeAll(keepingCapacity: true) }

    /// Returns a candidate whenever the stream currently looks like a loop -
    /// which means it keeps returning one, every atom, for as long as the user
    /// keeps going. Deciding when that is worth SAYING is the controller's job,
    /// not this one's.
    @discardableResult
    func ingest(_ atom: Atom) -> LoopCandidate? {
        guard atom.isSignal else { return nil }
        atoms.append(atom)
        if atoms.count > bufferCapacity {
            atoms.removeFirst(atoms.count - bufferCapacity)
        }
        return scan()
    }

    /// Stray steps tolerated inside one pass. One: a mis-click or a dismissed
    /// popup. Two starts merging genuinely different tasks (measured: it caused
    /// false positives on shuffled input), so noisier runs need consistency
    /// from the user instead.
    var slackPerPass = 1

    private func scan() -> LoopCandidate? {
        // Strict first: full identity, including titles, so a toolbar's
        // distinct buttons stay distinct. Only if that finds nothing do we
        // relax to structural identity, where a step's changing title becomes
        // its value - which is what rescues the drive-time / price / per-row
        // tasks whose values live in element titles.
        // Order by strength of evidence, not by which key is stricter:
        //   1. exact strict   - identical passes, full identity
        //   2. exact structural - identical STRUCTURE, values in titles differ
        //   3. tolerant strict - identical passes bar a stray step
        //   4. tolerant structural - the messiest real case
        // Exact-structural must beat tolerant-strict, or the tolerant scan
        // absorbs a step's changing value as "noise" and reports a shorter,
        // wrong loop - exactly what hid the drive-time task.
        return exactScan(structural: false)
            ?? exactScan(structural: true)
            ?? tolerantScan(structural: false)
            ?? tolerantScan(structural: true)
    }

    private func exactScan(structural: Bool) -> LoopCandidate? {
        let n = atoms.count
        guard n >= 3 else { return nil }

        for p in 1...min(maxPeriod, n / 2) {
            // Structural matching of a ONE-step period is too loose (every
            // click of the same role would merge); require a real sequence.
            if structural && p < 2 { continue }
            var m = 0
            while m + p < n,
                  atoms[n - 1 - m].matchKey(structural: structural)
                    == atoms[n - 1 - m - p].matchKey(structural: structural) {
                m += 1
            }
            // `m` trailing matches means the run spans m + p atoms: the matched
            // tail, plus the first repetition that seeded it.
            let covered = m + p
            let reps = covered / p
            let partial = covered % p

            // Fire as soon as the second full pass completes. The trailing
            // step is no longer required: waiting for it means a task done
            // exactly twice and then finished never gets offered, which is the
            // common case when someone is deciding whether this is worth
            // automating. A unit period is still held to a higher count,
            // because one repeated key is far more easily idle noise.
            let required = p == 1 ? minRepsForUnitPeriod : minCompleteReps * p
            guard covered >= required, reps >= minCompleteReps else { continue }

            let start = n - covered
            guard timingHolds(from: start) else { continue }

            if let c = build(start: start, period: p, reps: reps, partial: partial,
                             structural: structural),
               c.confidence >= minConfidence {
                return c
            }
        }
        return nil
    }

    // MARK: - Tolerant matching

    /// The exact scan, relaxed: each pass may contain up to `slackPerPass`
    /// atoms that are not part of the task.
    ///
    /// Why it exists: real tasks are never step-for-step identical. Someone
    /// mis-clicks, dismisses a popup, hits ⌘⇥ twice. Under exact matching a
    /// single stray click anywhere breaks the period, and the loop that a
    /// person would obviously call "the same thing four times" is invisible.
    ///
    /// Shape: pick a TEMPLATE (one clean pass), then walk backwards through the
    /// stream matching template steps in order, skipping at most one stray atom
    /// per pass. Stray atoms are excluded from the period and from the passes
    /// handed to binding inference, so they cannot become "steps".
    private func tolerantScan(structural: Bool) -> LoopCandidate? {
        let n = atoms.count
        guard n >= 5, slackPerPass > 0 else { return nil }
        let keys = atoms.map { $0.matchKey(structural: structural) }

        var best: (candidate: LoopCandidate, passes: Int, skips: Int)?

        for p in 2...min(maxPeriod, n / 2) {
            // How far into the next pass the user is. Required to be at least
            // one real step, as in the exact scan.
            for partial in 1..<p {
                // The partial region may carry one stray atom of its own.
                // Guarded: with a short stream the upper bound falls below the
                // lower one, and a closed range traps on that.
                let maxPartialLen = min(partial + slackPerPass, n - 2 * p)
                guard maxPartialLen >= partial else { continue }
                for partialLen in partial...maxPartialLen {
                    let templateEnd = n - partialLen
                    guard templateEnd >= 2 * p else { continue }
                    guard Self.prefixMatches(Array(keys[templateEnd..<n]),
                                             Array(keys[(templateEnd - p)..<(templateEnd - p + partial)]),
                                             slack: slackPerPass) else { continue }

                    // The template may come from ANY of the recent passes,
                    // because the most recent one might be the one with the
                    // stray atom in it.
                    let earliestTemplateEnd = max(p, templateEnd - p - slackPerPass)
                    for e in stride(from: templateEnd, through: earliestTemplateEnd, by: -1) {
                        let template = Array(keys[(e - p)..<e])
                        guard Set(template).count >= 2 else { continue }   // a run of one key is not a task
                        let (matched, passSkips) = Self.passesBackward(keys, end: templateEnd,
                                                                       template: template,
                                                                       slack: slackPerPass)
                        let partialSkips = partialLen - partial
                        let skips = passSkips + partialSkips
                        guard matched.count >= minCompleteReps, skips > 0 else { continue }
                        // skips == 0 would have been found by the exact scan.

                        // Tolerance is paid for with evidence. Two passes that
                        // only line up after ignoring something match a
                        // shuffled stream by accident far too often - measured
                        // on a four-symbol alphabet, which is about what a real
                        // screen full of buttons amounts to. So a stray inside
                        // a full pass needs a THIRD pass. A stray only in the
                        // trailing partial leaves the full passes exact, and
                        // exact evidence keeps the exact rules.
                        if passSkips > 0, matched.count < 3 { continue }

                        let start = matched.first!.first!
                        guard timingHolds(from: start) else { continue }
                        guard let c = build(matched: matched, partialLen: partial,
                                            skips: skips, structural: structural),
                              c.confidence >= minConfidence
                        else { continue }

                        if best == nil || matched.count > best!.passes
                            || (matched.count == best!.passes && skips < best!.skips) {
                            best = (c, matched.count, skips)
                        }
                    }
                }
                if best != nil { break }
            }
            if best != nil { return best!.candidate }   // shortest period wins
        }
        return nil
    }

    /// Does `segment` read as the first `prefix.count` steps of a pass, with at
    /// most `slack` stray atoms anywhere in it?
    private static func prefixMatches(_ segment: [UInt64], _ prefix: [UInt64],
                                      slack: Int) -> Bool {
        var j = 0, skips = 0
        for k in segment {
            if j < prefix.count, k == prefix[j] { j += 1 }
            else { skips += 1; if skips > slack { return false } }
        }
        return j == prefix.count
    }

    /// Walks backwards from `end`, matching whole passes of `template` and
    /// tolerating `slack` strays per pass. Returns the stream indices matched
    /// to each template step, oldest pass first, plus the total strays skipped.
    private static func passesBackward(_ keys: [UInt64], end: Int, template: [UInt64],
                                       slack: Int) -> (passes: [[Int]], skips: Int) {
        let p = template.count
        var passes: [[Int]] = []
        var totalSkips = 0
        var i = end - 1
        while passes.count < 8 {
            var j = p - 1
            var skips = 0
            var indices = [Int](repeating: -1, count: p)
            var ii = i
            while j >= 0, ii >= 0 {
                if keys[ii] == template[j] { indices[j] = ii; ii -= 1; j -= 1 }
                else if skips < slack { skips += 1; ii -= 1 }
                else { break }
            }
            guard j < 0 else { break }
            passes.insert(indices, at: 0)
            totalSkips += skips
            i = ii
        }
        return (passes, totalSkips)
    }

    /// Builds a candidate from explicitly matched passes.
    private func build(matched: [[Int]], partialLen: Int, skips: Int,
                       structural: Bool = false) -> LoopCandidate? {
        let reps = matched.count
        guard let lastPass = matched.last, let firstPass = matched.first,
              let start = firstPass.first else { return nil }
        let p = lastPass.count
        let period = lastPass.map { atoms[$0] }
        let passes = matched.suffix(6).map { $0.map { atoms[$0] } }

        var varying = Set<Int>()
        for k in 0..<p {
            let baseVary = atoms[firstPass[k]].varyKey
            let baseStrict = atoms[firstPass[k]].strictKey
            for pass in matched.dropFirst() {
                let a = atoms[pass[k]]
                if a.varyKey != baseVary || (structural && a.strictKey != baseStrict) {
                    varying.insert(k); break
                }
            }
        }

        var durations = [Double]()
        for pass in matched {
            durations.append(Double(atoms[pass[p - 1]].end &- atoms[pass[0]].start) / 1e9)
        }
        let mean = durations.reduce(0, +) / Double(durations.count)
        let variance = durations.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(durations.count)
        let regularity = mean > 0.05 ? max(0, 1 - (variance.squareRoot() / mean)) : 0.5
        let distinct = Double(Set(period.map(\.strictKey)).count) / Double(p)
        let repTerm = min(1.0, Double(reps - 1) / 3.0)
        // Each stray costs a little: a loop that only lines up after ignoring
        // things is real, but less certainly so.
        let confidence = max(0, min(1.0,
            0.40 * repTerm + 0.25 * regularity + 0.20 * distinct + 0.15
            - 0.05 * Double(skips)))

        var c = LoopCandidate(
            patternID: Self.patternID(period.map { $0.matchKey(structural: structural) }),
            period: period,
            completeReps: reps,
            partialSteps: partialLen,
            varyingSteps: varying,
            recentPasses: passes,
            confidence: confidence,
            meanRepSeconds: mean,
            firstStart: atoms[start].start,
            lastEnd: atoms[atoms.count - 1].end)
        c.strayStepsIgnored = skips
        return c
    }

    private func timingHolds(from start: Int) -> Bool {
        let n = atoms.count
        guard atoms[n - 1].end &- atoms[start].start <= maxSpanNS else { return false }
        var i = start + 1
        while i < n {
            if atoms[i].start &- atoms[i - 1].end > maxGapNS { return false }
            i += 1
        }
        return true
    }

    private func build(start: Int, period p: Int, reps: Int, partial: Int,
                       structural: Bool = false) -> LoopCandidate? {
        let n = atoms.count
        // The last COMPLETE pass, i.e. skipping back over the partial one the
        // user is in the middle of right now.
        let periodEnd = n - partial
        let periodStart = periodEnd - p
        guard periodStart >= 0 else { return nil }
        let period = Array(atoms[periodStart..<periodEnd])

        // Which steps changed value between passes. Under structural matching a
        // step also "varies" when its full identity (title) differs across
        // passes - that title IS the value (the drive time, the address).
        var varying = Set<Int>()
        for k in 0..<p {
            let baseVary = atoms[start + k].varyKey
            let baseStrict = atoms[start + k].strictKey
            for r in 1..<reps {
                let a = atoms[start + r * p + k]
                if a.varyKey != baseVary || (structural && a.strictKey != baseStrict) {
                    varying.insert(k); break
                }
            }
        }

        // Capped: six passes is more than enough to establish a stride, and
        // an unbounded copy would grow with a loop someone leaves running.
        var passes: [[Atom]] = []
        for r in max(0, reps - 6)..<reps {
            passes.append(Array(atoms[(start + r * p)..<(start + r * p + p)]))
        }

        // Rep durations, for the regularity term and for the UI's "~4s each".
        var durations = [Double]()
        for r in 0..<reps {
            let a = atoms[start + r * p], b = atoms[start + r * p + p - 1]
            durations.append(Double(b.end &- a.start) / 1e9)
        }
        let mean = durations.reduce(0, +) / Double(durations.count)
        let variance = durations.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(durations.count)
        let regularity = mean > 0.05
            ? max(0, 1 - (variance.squareRoot() / mean)) : 0.5

        // A period of p identical steps is weaker evidence than p distinct
        // ones: the first is what idle clicking looks like.
        let distinct = Double(Set(period.map(\.strictKey)).count) / Double(p)

        let repTerm = min(1.0, Double(reps - 1) / 3.0)
        let confidence = min(1.0,
            0.40 * repTerm + 0.25 * regularity + 0.20 * distinct
            + (p >= 2 ? 0.15 : 0.0))

        return LoopCandidate(
            patternID: Self.patternID(period.map { $0.matchKey(structural: structural) }),
            period: period,
            completeReps: reps,
            partialSteps: partial,
            varyingSteps: varying,
            recentPasses: passes,
            confidence: confidence,
            meanRepSeconds: mean,
            firstStart: atoms[start].start,
            lastEnd: atoms[n - 1].end)
    }

    /// Hash of the lexicographically smallest rotation.
    ///
    /// The same loop detected mid-pass starts at a different step - "BCA"
    /// rather than "ABC" - and without normalizing that away, dismissing a
    /// suggestion would silence only the rotation the user happened to be
    /// caught in. O(p²) with p ≤ 16.
    static func patternID(_ keys: [UInt64]) -> UInt64 {
        let n = keys.count
        guard n > 0 else { return 0 }
        var best = 0
        for r in 1..<max(n, 1) {
            var i = 0
            while i < n, keys[(best + i) % n] == keys[(r + i) % n] { i += 1 }
            if i < n, keys[(r + i) % n] < keys[(best + i) % n] { best = r }
        }
        var h = FNV1a()
        h.combine(n)
        for i in 0..<n { h.combine(keys[(best + i) % n]) }
        return h.value
    }
}
