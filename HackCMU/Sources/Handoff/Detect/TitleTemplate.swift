import Foundation

/// The stable shape of an element's title across passes, when the title carries
/// a changing value.
///
/// The Maps tab is "Salesforce Tower to <address> - Google Maps"; the address
/// changes, but "Salesforce Tower to " and " - Google Maps" do not. That common
/// prefix and suffix are enough to find the tab again next pass, whatever the
/// address is. This is how a step whose identity is a VALUE gets a stable
/// replay target without Handoff having to understand the value.
struct TitleTemplate: Sendable, Equatable, Codable {
    var prefix: String
    var suffix: String
    /// A digit-masked shape, for titles that vary only in numbers ("19 min",
    /// "8 min" -> "# min"). Used when prefix/suffix are too thin to match on.
    var shape: String
    /// Longest common digit-masked PREFIX ("# min" for "17 min" and
    /// "27 min (4.9 miles)"). The loosest fallback, for when the user clicked
    /// structurally different elements that still start the same way - and, on
    /// a page with two routes, it matches the FIRST, which is the top route.
    var maskedPrefix: String = ""

    /// True when the affixes alone pin the element down well enough to click.
    var isSpecific: Bool { prefix.count + suffix.count >= 4 }
    private var hasMaskedPrefix: Bool {
        maskedPrefix.contains(where: \.isLetter) && maskedPrefix.count >= 3
    }

    func matches(_ title: String) -> Bool {
        if isSpecific {
            return title.hasPrefix(prefix) && title.hasSuffix(suffix)
                && title.count >= prefix.count + suffix.count
        }
        if !shape.isEmpty, Self.mask(title) == shape { return true }
        if hasMaskedPrefix { return Self.mask(title).hasPrefix(maskedPrefix) }
        return false
    }

    var describe: String {
        if isSpecific {
            let mid = prefix.isEmpty ? "" : "\u{2026}"
            return "the \"\(prefix)\(mid)\(suffix)\"".trimmingCharacters(in: .whitespaces) + " control"
        }
        let shown = shape.isEmpty ? maskedPrefix : shape
        return "the \"\(shown)\u{2026}\" value"
    }

    /// Longest common prefix + suffix, plus the digit-masked shape if every
    /// title shares one. Returns nil when the titles have nothing in common -
    /// which means the step is genuinely unpredictable, not a template.
    static func infer(_ titles: [String]) -> TitleTemplate? {
        let clean = titles.filter { !$0.isEmpty }
        guard clean.count >= 2 else { return nil }
        let prefix = commonPrefix(clean)
        let suffix = commonSuffix(clean, excluding: prefix.count)
        let masks = clean.map(mask)
        let shape = Set(masks).count == 1 ? (masks.first ?? "") : ""
        let maskedPrefix = commonPrefix(masks)
        var tpl = TitleTemplate(prefix: prefix, suffix: suffix, shape: shape)
        tpl.maskedPrefix = maskedPrefix
        // Something must be stable, or it is not a template at all.
        guard tpl.isSpecific || !shape.isEmpty || tpl.hasMaskedPrefix else { return nil }
        return tpl
    }

    static func mask(_ s: String) -> String {
        var out = ""; var inNum = false
        for ch in s {
            if ch.isNumber { if !inNum { out.append("#"); inNum = true } }
            else { out.append(ch); inNum = false }
        }
        return out
    }

    private static func commonPrefix(_ ss: [String]) -> String {
        guard var p = ss.first else { return "" }
        for s in ss.dropFirst() {
            while !s.hasPrefix(p) { p = String(p.dropLast()) ; if p.isEmpty { return "" } }
        }
        return p
    }
    private static func commonSuffix(_ ss: [String], excluding prefixLen: Int) -> String {
        guard var suf = ss.first else { return "" }
        for s in ss.dropFirst() {
            while !s.hasSuffix(suf) { suf = String(suf.dropFirst()); if suf.isEmpty { return "" } }
        }
        // Don't let prefix and suffix overlap on the shortest title.
        let minLen = ss.map(\.count).min() ?? 0
        while suf.count + prefixLen > minLen, !suf.isEmpty { suf = String(suf.dropFirst()) }
        return suf
    }
}
