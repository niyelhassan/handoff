import ApplicationServices
import Foundation

/// Turns a click coordinate into an `AXTarget`.
///
/// ENRICH QUEUE ONLY - every call inside is synchronous IPC.
///
/// Timing caveat worth knowing: the hit test happens a few milliseconds AFTER
/// the click, so a click that dismisses its own target (a menu item, a button
/// that navigates) can resolve to nothing or to whatever replaced it. The 8ms
/// drain keeps that window small, and an unresolved click degrades to the
/// coordinate path rather than failing.
protocol TargetResolver: AnyObject {
    func resolve(pid: Int32, x: Float, y: Float) -> AXTarget?
    /// Numbers currently visible on an app's front window, for the
    /// read-and-retype case. Default is none, so test doubles need not care.
    func numericReadouts(pid: Int32, bundleID: String, appName: String) -> [ScreenReadout]
    /// The active web tab's URL + numbers, for same-window tab tasks.
    func activeBrowserContext(pid: Int32, bundleID: String, appName: String)
        -> (url: String, readouts: [ScreenReadout])?
}

extension TargetResolver {
    func numericReadouts(pid: Int32, bundleID: String, appName: String) -> [ScreenReadout] { [] }
    func activeBrowserContext(pid: Int32, bundleID: String, appName: String)
        -> (url: String, readouts: [ScreenReadout])? { nil }
}

final class AXResolver: TargetResolver {

    /// Scoped deliberately. The probe measured Chrome exposing a 118-node stub
    /// of page content even with AXManualAccessibility forced, so promising
    /// element-level replay there would be a lie. Finder and Safari both expose
    /// real trees with no coaxing.
    static let supported: Set<String> = [
        "com.apple.finder", "com.apple.Safari",
    ]
    /// Apps where a URL is worth looking for.
    static let browsers: Set<String> = ["com.apple.Safari"]

    /// Walking to the window is bounded: Safari's tree runs 13 deep and a
    /// runaway AXParent chain would otherwise be unbounded IPC.
    private let maxDepth = 20
    /// Scanning a container's children to find an ordinal is one IPC for the
    /// array but O(n) attribute reads after it. Past this, fall back to
    /// whatever the element reports about itself.
    private let maxSiblingScan = 400

    private var enabled = true

    func setEnabled(_ on: Bool) { enabled = on }

    func resolve(pid: Int32, x: Float, y: Float) -> AXTarget? {
        guard enabled, AXIsProcessTrusted() else { return nil }
        guard let hit = AX.hitTest(pid: pid_t(pid), x: x, y: y) else { return nil }

        // Chain from the clicked element up toward the window.
        var chain: [AXUIElement] = [hit]
        var roles: [String] = [AX.role(hit)]
        var node = hit
        while chain.count < maxDepth, let p = AX.parent(node) {
            let r = AX.role(p)
            chain.append(p)
            roles.append(r)
            node = p
            if r == kAXWindowAttribute || r == "AXWindow" { break }
        }

        // The deepest element is rarely the right one. Clicking a file in
        // Finder lands on an AXTextField, three levels inside the AXRow, whose
        // title is the FILENAME - so anchoring on it would give every file its
        // own identity and the loop would never match itself. Anchor on the
        // nearest ancestor that sits inside a collection instead; that is the
        // thing being iterated, and the thing that carries a bound.
        let leafTitle = AX.stableTitle(hit)
        var anchor = 0
        var ordinal = 0
        var siblingCount = 1

        for i in 0..<max(chain.count - 1, 1) where i < chain.count - 1 {
            let parentRole = roles[i + 1]
            // Counting siblings costs an IPC per candidate, so only pay it
            // where the container could plausibly be a collection at all.
            let plausible = AXTarget.collectionContainerRoles.contains(parentRole)
                || roles[i] == "AXLink" || roles[i] == "AXRow"
            guard plausible, !AXTarget.fixedContainerRoles.contains(parentRole) else {
                continue
            }
            let (ord, n) = position(of: chain[i], role: roles[i], in: chain[i + 1])
            if AXTarget.enumerable(role: roles[i], parentRole: parentRole, siblings: n) {
                anchor = i; ordinal = ord; siblingCount = n
                break
            }
        }

        let el = chain[anchor]
        let role = roles[anchor]
        let subrole = AX.string(el, kAXSubroleAttribute as String)
        // Window-first reads the way a person would describe the location.
        let rolePath = roles[anchor...].reversed().joined(separator: "/")

        var containerPath: String?
        var containerRole: String?
        var containerTitle: String?
        if chain.count > anchor + 1 {
            containerRole = roles[anchor + 1]
            containerPath = roles[(anchor + 1)...].reversed().joined(separator: "/")
            containerTitle = AX.stableTitle(chain[anchor + 1])
            if anchor == 0 {
                (ordinal, siblingCount) = position(of: el, role: role,
                                                   in: chain[anchor + 1])
            }
        }

        let enumerable = AXTarget.enumerable(role: role,
                                             parentRole: containerRole ?? "",
                                             siblings: siblingCount)
        let texts = readableTexts(of: el)
        let windowTitle = chain.last.flatMap { AX.stableTitle($0) }

        return AXTarget(
            role: role,
            subrole: subrole,
            title: AX.stableTitle(el),
            identifier: AX.string(el, kAXIdentifierAttribute as String)
                .flatMap { $0.isEmpty ? nil : $0 },
            rolePath: rolePath,
            containerPath: containerPath,
            containerRole: containerRole,
            containerTitle: containerTitle,
            ordinal: ordinal,
            siblingCount: siblingCount,
            isEnumerable: enumerable,
            actions: AX.actions(el).filter { $0 != kAXShowMenuAction as String },
            url: browserURL(chain: chain, roles: roles),
            windowTitle: windowTitle,
            itemName: leafTitle ?? texts.first,
            texts: texts)
    }

    // MARK: - Ordinal and bound

    /// Returns (ordinal, siblingCount) among same-role siblings.
    ///
    /// `AXIndex` and the container's `AXRows` are checked first because they
    /// answer both questions in one IPC each. Finder populates both, which is
    /// what makes the loop bound free there rather than a 31-element scan.
    private func position(of el: AXUIElement, role: String,
                          in parent: AXUIElement) -> (Int, Int) {
        let rows = AX.elements(parent, "AXRows")
        let declaredCount = rows.isEmpty ? nil : rows.count

        if let idx = AX.int(el, "AXIndex"), let n = declaredCount, idx >= 0, idx < n {
            return (idx, n)
        }

        let kids = AX.children(parent)
        guard kids.count <= maxSiblingScan else {
            // Too many to enumerate cheaply. AXIndex alone still gives a usable
            // ordinal; the bound stays unknown rather than wrong.
            return (AX.int(el, "AXIndex") ?? 0, declaredCount ?? kids.count)
        }

        var ordinal = 0
        var count = 0
        var found = false
        for k in kids where AX.role(k) == role {
            if !found, CFEqual(k, el) { ordinal = count; found = true }
            count += 1
        }
        if !found { ordinal = AX.int(el, "AXIndex") ?? 0 }
        return (ordinal, max(count, declaredCount ?? 0, 1))
    }

    /// Every distinct readable string under an element, in tree order.
    ///
    /// Order matters and is stable: for a table row it is the columns, left to
    /// right, so "the second text of this row" keeps meaning the same field on
    /// the next pass. That stability is what a value binding is pinned to.
    /// Tightly bounded - this runs on every click.
    /// Depth 5, not 3: real web apps nest their text far deeper than a native
    /// table does. A Gmail row is AXRow > AXCell > AXGroup > AXGroup >
    /// AXStaticText, so stopping at 3 comes back empty and every value binding
    /// starves for want of anything to bind to.
    func readableTexts(of el: AXUIElement, limit: Int = 12) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var budget = 60          // hard ceiling on IPC, whatever the shape
        func walk(_ node: AXUIElement, _ depth: Int) {
            guard out.count < limit, depth <= 5, budget > 0 else { return }
            budget -= 1
            if let t = AX.stableTitle(node), seen.insert(t).inserted { out.append(t) }
            for c in AX.children(node).prefix(10) {
                guard out.count < limit, budget > 0 else { return }
                walk(c, depth + 1)
            }
        }
        walk(el, 0)
        return out
    }

    /// The active web area's URL and the numbers visible under it, for a
    /// browser. Keyed on the URL so a value read in one tab can be matched to
    /// the tab it came from, even after the user switches away - which is the
    /// whole difficulty of an all-in-one-window tab task: the backgrounded tab
    /// leaves the AX tree, so it has to have been snapshotted while active.
    func activeBrowserContext(pid: Int32, bundleID: String, appName: String)
        -> (url: String, readouts: [ScreenReadout])? {
        guard AXIsProcessTrusted() else { return nil }
        let appEl = AX.app(pid_t(pid))
        guard let win = AX.elements(appEl, kAXWindowsAttribute as String).first else { return nil }

        // Find the active web area (bounded BFS - page content hangs off it).
        var web: AXUIElement?
        var frontier = [win]; var budget = 400
        while !frontier.isEmpty, web == nil, budget > 0 {
            var next: [AXUIElement] = []
            for el in frontier {
                budget -= 1
                if AX.role(el) == "AXWebArea" { web = el; break }
                next += AX.children(el)
            }
            frontier = next
        }
        guard let web else { return nil }
        let url = AX.string(web, "AXURL") ?? AX.string(web, kAXValueAttribute as String) ?? ""

        var out: [ScreenReadout] = []
        var seen = Set<String>()
        budget = 600
        func walk(_ el: AXUIElement, _ roles: [String], _ depth: Int) {
            guard budget > 0, depth < 16, out.count < 30 else { return }
            budget -= 1
            let role = AX.role(el)
            let path = roles + [role]
            if let t = AX.stableTitle(el) {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count <= 24, trimmed.contains(where: \.isNumber),
                   seen.insert(trimmed).inserted {
                    out.append(ScreenReadout(bundleID: bundleID, appName: appName,
                                             rolePath: path.joined(separator: "/"),
                                             role: role, text: trimmed))
                }
            }
            for c in AX.children(el) { walk(c, path, depth + 1) }
        }
        walk(web, ["AXWindow"], 0)   // stable prefix so replay can re-find it
        return (url, out)
    }

    /// Short strings containing a number, from an app's front window, with the
    /// role path to re-read each. This is how "24 min" on a non-frontmost Maps
    /// window is found again. Bounded hard - it runs when a value is typed.
    func numericReadouts(pid: Int32, bundleID: String, appName: String) -> [ScreenReadout] {
        guard AXIsProcessTrusted() else { return [] }
        let appEl = AX.app(pid_t(pid))
        guard let win = AX.elements(appEl, kAXWindowsAttribute as String).first else { return [] }
        var out: [ScreenReadout] = []
        var seen = Set<String>()
        var budget = 500
        func walk(_ el: AXUIElement, _ roles: [String], _ depth: Int) {
            guard budget > 0, depth < 16, out.count < 30 else { return }
            budget -= 1
            let role = AX.role(el)
            let path = (roles + [role])
            if let t = AX.stableTitle(el) {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                // A readout is short and contains a digit: "24 min", "1.3 mi",
                // "20–35 min". Long text is prose, not a value.
                if trimmed.count <= 24, trimmed.contains(where: \.isNumber),
                   seen.insert(trimmed).inserted {
                    out.append(ScreenReadout(bundleID: bundleID, appName: appName,
                                             rolePath: path.joined(separator: "/"),
                                             role: role, text: trimmed))
                }
            }
            for c in AX.children(el) { walk(c, path, depth + 1) }
        }
        walk(win, [], 0)
        return out
    }

    // MARK: - Re-finding an element later

    /// Walks a recorded `rolePath` back to a live element.
    ///
    /// This is the point of storing a path rather than a coordinate: the window
    /// may have moved, been resized, or scrolled since, and this returns
    /// wherever the container is NOW. Ambiguous levels are tried in order and
    /// backtracked, because a role alone is not always unique.
    func locate(pid: Int32, path: String, title: String? = nil,
                titleHash: UInt64? = nil) -> AXUIElement? {
        let roles = path.split(separator: "/").map(String.init)
        guard let first = roles.first else { return nil }
        var budget = 4000

        let appEl = AX.app(pid_t(pid))
        let roots = first == "AXWindow"
            ? AX.elements(appEl, kAXWindowsAttribute as String)
            : [appEl]

        // EVERY match, not the first: in Finder the sidebar and the file list
        // share the path AXWindow/AXSplitGroup/AXSplitGroup/AXScrollArea/
        // AXOutline, so stopping at the first one picks the sidebar about half
        // the time. The title is what tells them apart.
        var matches: [AXUIElement] = []
        for root in roots where AX.role(root) == first {
            descend(root, Array(roles), &budget, into: &matches)
            if matches.count >= 8 { break }
        }
        if let title, let exact = matches.first(where: { AX.stableTitle($0) == title }) {
            return exact
        }
        // A pattern from memory knows the label only as a hash.
        if let titleHash, let exact = matches.first(where: {
            AX.stableTitle($0).map(AXTarget.hash) == titleHash
        }) {
            return exact
        }
        return matches.first
    }

    private func descend(_ el: AXUIElement, _ roles: [String],
                         _ budget: inout Int, into out: inout [AXUIElement]) {
        guard budget > 0, out.count < 8 else { return }
        budget -= 1
        if roles.count == 1 { out.append(el); return }
        let next = roles[1]
        let rest = Array(roles.dropFirst())
        for child in AX.children(el) where AX.role(child) == next {
            descend(child, rest, &budget, into: &out)
        }
    }

    /// Among the elements at a role path, the one whose title fits a template.
    /// This is how a varying click - the Maps tab named after the current row,
    /// the "N min" result - is re-found next pass.
    func locateMatching(pid: Int32, path: String, template: TitleTemplate) -> AXUIElement? {
        let roles = path.split(separator: "/").map(String.init)
        guard let first = roles.first else { return nil }
        var budget = 4000
        let appEl = AX.app(pid_t(pid))
        let roots = first == "AXWindow"
            ? AX.elements(appEl, kAXWindowsAttribute as String) : [appEl]
        var matches: [AXUIElement] = []
        for root in roots where AX.role(root) == first {
            descend(root, Array(roles), &budget, into: &matches)
        }
        return matches.first { AX.stableTitle($0).map(template.matches) ?? false }
    }

    /// The nth same-role item, counted the SAME way `position(of:)` counted it -
    /// AXRows first - or the ordinals recorded during capture will not line up
    /// with the ones used during replay.
    func item(in container: AXUIElement, role: String, ordinal: Int) -> AXUIElement? {
        guard ordinal >= 0 else { return nil }
        let rows = AX.elements(container, "AXRows")
        if !rows.isEmpty { return ordinal < rows.count ? rows[ordinal] : nil }
        let matching = AX.children(container).filter { AX.role($0) == role }
        return ordinal < matching.count ? matching[ordinal] : nil
    }

    /// Live screen rect of an element, or nil if it has none.
    func frame(of el: AXUIElement) -> CGRect? {
        guard let o = AX.point(el, kAXPositionAttribute as String),
              let sz = AX.size(el, kAXSizeAttribute as String),
              sz.width > 0, sz.height > 0 else { return nil }
        return CGRect(origin: o, size: sz)
    }

    // MARK: - Browser context

    /// The page the click happened on.
    ///
    /// AXWebArea's AXURL is preferred and the omnibox is the fallback, in that
    /// order, because the probe found pages with no AXWebArea at all - on which
    /// the omnibox is the only source and therefore load-bearing.
    private func browserURL(chain: [AXUIElement], roles: [String]) -> String? {
        for (i, r) in roles.enumerated() where r == "AXWebArea" {
            for key in ["AXURL", kAXValueAttribute as String] {
                if let u = AX.string(chain[i], key), !u.isEmpty { return u }
            }
        }
        guard let window = chain.last else { return nil }
        return omnibox(in: window, depth: 0)
    }

    /// Bounded search for the address field. Depth 6 reaches Safari's toolbar
    /// without descending into page content, which is the expensive half of the
    /// tree and never holds the omnibox.
    private func omnibox(in el: AXUIElement, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        let role = AX.role(el)
        if role == "AXTextField" || role == "AXComboBox" {
            let hint = [AX.string(el, kAXDescriptionAttribute as String),
                        AX.string(el, kAXTitleAttribute as String),
                        AX.string(el, kAXIdentifierAttribute as String)]
                .compactMap { $0 }.joined(separator: " ").lowercased()
            if hint.contains("address") || hint.contains("url")
                || hint.contains("location") || hint.contains("search") {
                if let v = AX.string(el, kAXValueAttribute as String), !v.isEmpty {
                    return v
                }
            }
        }
        // Page content hangs off scroll areas and web areas; skipping them keeps
        // this to the window furniture.
        if role == "AXWebArea" || role == "AXScrollArea" { return nil }
        for c in AX.children(el).prefix(20) {
            if let found = omnibox(in: c, depth: depth + 1) { return found }
        }
        return nil
    }
}
