import Foundation

/// How the number a person typed relates to the number they were looking at.
///
/// The read-and-retype case: Maps shows "24 min", they type 24. Maps shows a
/// traffic range "20–35 min", they type... which one? That is not knowable in
/// the abstract - it is a CONVENTION the person has, and the only way to get it
/// right is to see what they did and do the same. So this is inferred from the
/// pair (what was shown, what was typed), then reproduced.
struct NumberTransform: Sendable, Equatable, Codable {

    enum Pick: String, Sendable, Codable {
        case first        // "24 min" -> 24; "20–35" -> 20
        case last         // "20–35 min" -> 35
        case midpoint     // "20–35 min" -> 27 (or 28)
        case wholeString  // not a clean number: type the text verbatim
    }

    var pick: Pick
    /// Which number in the string, when there are several unrelated ones
    /// ("2 routes, 24 min, 1.3 mi"). Index into the numbers found, left to
    /// right. `pick` then applies within the chosen run.
    var fieldIndex: Int

    /// All integer/decimal runs in a string, left to right, as (value, isRange
    /// with the next). Ranges are "20–35", "20-35", "20 to 35".
    static func numbers(in s: String) -> [Double] {
        var out: [Double] = []
        var cur = ""
        func flush() {
            if let v = Double(cur) { out.append(v) }
            cur = ""
        }
        for ch in s {
            if ch.isNumber || (ch == "." && !cur.isEmpty) { cur.append(ch) }
            else { flush() }
        }
        flush()
        return out
    }

    /// Detects the transform, or nil if the typed value is not explained by the
    /// shown text.
    static func infer(shown: String, typed: String) -> NumberTransform? {
        let typedTrim = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let typedNum = Double(typedTrim) else {
            // Non-numeric: only a verbatim match counts (e.g. a city name read
            // off a header). Rare, but keeps the door open.
            return shown.contains(typedTrim) && typedTrim.count >= 3
                ? NumberTransform(pick: .wholeString, fieldIndex: 0) : nil
        }
        let nums = numbers(in: shown)
        guard !nums.isEmpty else { return nil }

        // Consider each number, and each number paired with the next as a range.
        for (i, n) in nums.enumerated() {
            if approx(n, typedNum) { return NumberTransform(pick: .first, fieldIndex: i) }
            if i + 1 < nums.count {
                let hi = nums[i + 1]
                if approx(hi, typedNum) { return NumberTransform(pick: .last, fieldIndex: i) }
                let mid = (n + hi) / 2
                if approx(mid, typedNum) || approx(mid.rounded(), typedNum)
                    || approx(mid.rounded(.down), typedNum) || approx(mid.rounded(.up), typedNum) {
                    return NumberTransform(pick: .midpoint, fieldIndex: i)
                }
            }
        }
        return nil
    }

    /// Applies the transform to a freshly read string.
    func apply(to shown: String) -> String? {
        if pick == .wholeString {
            return shown.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nums = Self.numbers(in: shown)
        guard fieldIndex < nums.count else {
            // The layout changed - fewer numbers than when learned. Fall back
            // to the first number rather than typing nonsense.
            guard let first = nums.first else { return nil }
            return Self.format(first)
        }
        switch pick {
        case .first:
            return Self.format(nums[fieldIndex])
        case .last:
            return Self.format(fieldIndex + 1 < nums.count ? nums[fieldIndex + 1] : nums[fieldIndex])
        case .midpoint:
            guard fieldIndex + 1 < nums.count else { return Self.format(nums[fieldIndex]) }
            return Self.format(((nums[fieldIndex] + nums[fieldIndex + 1]) / 2).rounded())
        case .wholeString:
            return shown
        }
    }

    /// Human description for the confirmation window.
    var describe: String {
        switch pick {
        case .first:       return "the drive time shown"
        case .last:        return "the higher end of the range shown"
        case .midpoint:    return "the middle of the range shown"
        case .wholeString: return "the text shown"
        }
    }

    private static func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }

    /// Integers print without a decimal point; "24", not "24.0".
    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}
