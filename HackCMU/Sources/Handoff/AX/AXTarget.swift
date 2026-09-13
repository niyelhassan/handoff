import ApplicationServices
import Foundation

/// A click resolved to an actual interface element.
///
/// This is what replaces coordinate banding as the identity of a click. The
/// distinction that makes a loop detectable lives in one field: `isEnumerable`.
///
///   - A toolbar button is a FIXED control. Its title is its identity - "Share"
///     and "Archive" sit side by side and must never collapse into one step.
///   - A table row is an ENUMERABLE item. Its position is a VALUE, not an
///     identity - row 3 and row 4 are the same step of a loop, done twice.
///
/// Getting that backwards in either direction breaks detection: conflating two
/// buttons invents loops that do not exist, and separating two rows hides the
/// only loop anyone actually runs.
struct AXTarget: Sendable {
    var role: String
    var subrole: String?
    var title: String?
    /// kAXIdentifier. The probe measured this at 0-10% coverage, so it is a
    /// bonus that strengthens identity when present and is never required.
    var identifier: String?

    /// Roles from the window down to this element: the structural address.
    var rolePath: String
    /// The rolePath of the enclosing container. For an enumerable item this is
    /// the stable half of its identity - "a row in THAT table".
    var containerPath: String?
    var containerRole: String?
    var containerTitle: String?

    /// Position among same-role siblings, 0-based.
    var ordinal: Int
    /// How many same-role siblings the container holds. For an enumerable item
    /// this is the LOOP BOUND - the reason "the rest" can mean a number.
    var siblingCount: Int
    /// Whether `ordinal` is a value that may vary between passes rather than
    /// part of the element's identity.
    var isEnumerable: Bool

    /// Non-empty when the element can be driven through Accessibility rather
    /// than by synthesizing a click at a coordinate.
    var actions: [String]
    /// Browser task context - the page this happened on.
    var url: String?
    var windowTitle: String?
    /// What was literally under the pointer, when that is deeper than the
    /// anchor. A Finder row carries no title of its own; the filename lives on
    /// a text field three levels down, and it is the only part a person would
    /// recognise. Display only - never part of identity, because it is exactly
    /// the thing that changes every pass.
    var itemName: String?

    /// Readable text of this element and its descendants, in tree order.
    ///
    /// This is what makes data movement inferable: when step 5 types the same
    /// string that sits at `texts[1]` of the row clicked in step 1, that is not
    /// a coincidence, it is a copy - and on the next pass the value can be read
    /// from the next row instead of guessed at. Order is stable (for a row it
    /// is the columns, left to right), so an index keeps meaning the same
    /// field. Bounded, because a row's subtree is not small.
    var texts: [String] = []

    /// FNV-1a of `containerTitle`, for a target rebuilt from memory. The label
    /// itself is not stored on disk; the hash is enough to tell "the outline
    /// titled list view" from the sidebar's outline when re-finding it.
    var containerTitleHash: UInt64? = nil

    static func hash(_ s: String) -> UInt64 { var h = FNV1a(); h.combine(s); return h.value }

    var canPress: Bool { actions.contains(kAXPressAction as String) }

    /// A short human label: "row 4 of 31 in Documents", "the Archive button".
    var describe: String {
        if isEnumerable {
            let name = title ?? itemName
            let what = name.map { "\"\($0)\"" } ?? Self.friendlyRole(role)
            let whereIn = containerTitle.map { " in \($0)" } ?? ""
            return "\(what) - item \(ordinal + 1) of \(siblingCount)\(whereIn)"
        }
        if let t = title { return "\(Self.friendlyRole(role)) \"\(t)\"" }
        return Self.friendlyRole(role)
    }

    static func friendlyRole(_ r: String) -> String {
        switch r {
        case "AXButton":     return "button"
        case "AXRow", "AXOutlineRow": return "row"
        case "AXCell":       return "cell"
        case "AXLink":       return "link"
        case "AXTextField":  return "text field"
        case "AXCheckBox":   return "checkbox"
        case "AXMenuItem":   return "menu item"
        case "AXStaticText": return "text"
        case "AXImage":      return "image"
        default:
            return r.hasPrefix("AX") ? String(r.dropFirst(2)).lowercased() : r
        }
    }

    // MARK: - Identity

    /// What must match for two clicks to be the same step.
    func strictKey(bundleID: String, kind: AtomKind) -> UInt64 {
        var h = FNV1a()
        h.combine(UInt64(kind.rawValue))
        h.combine(bundleID)
        if isEnumerable {
            // The container is the identity; which item was picked is not.
            h.combine(containerPath ?? rolePath)
            h.combine(role)
        } else {
            h.combine(rolePath)
            h.combine(role)
            // A button's label IS the button. Two toolbar buttons share a
            // rolePath and are told apart by nothing else.
            h.combine(title ?? "")
            h.combine(identifier ?? "")
        }
        return h.value
    }

    /// Identity by structural POSITION only - never the title. This is what
    /// lets a step that shows a different value each pass (a duration, a price,
    /// a tab named after the current row) still be recognised as the same step.
    func structuralKey(bundleID: String, kind: AtomKind) -> UInt64 {
        var h = FNV1a()
        h.combine(UInt64(kind.rawValue))
        h.combine(bundleID)
        h.combine(isEnumerable ? (containerPath ?? rolePath) : rolePath)
        h.combine(role)
        return h.value
    }

    /// The value shown, for a structural match: the title/name is the parameter.
    func titleValueKey() -> UInt64 {
        var h = FNV1a()
        h.combine(title ?? itemName ?? "")
        return h.value
    }

    /// What is allowed to differ between passes.
    func varyKey() -> UInt64 {
        guard isEnumerable else { return 0 }
        var h = FNV1a()
        h.combine(ordinal)
        return h.value
    }

    // MARK: - Collection heuristics

    /// Containers whose children are a homogeneous list: position is a value.
    static let collectionContainerRoles: Set<String> = [
        "AXTable", "AXOutline", "AXList", "AXGrid", "AXCollection", "AXBrowser",
    ]
    /// Containers whose children are DISTINCT controls that happen to share a
    /// role. Position here is identity, not a value - without this list every
    /// toolbar in macOS reads as a four-item loop.
    static let fixedContainerRoles: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXMenuBarItem",
        "AXTabGroup", "AXRadioGroup", "AXSplitGroup",
    ]

    /// Decided by the CONTAINER, never by the element's own role.
    ///
    /// Keying off the element instead is a trap worth naming: `AXCell` looks
    /// like a collection item, but in Finder's list view a cell's siblings are
    /// the COLUMNS - Name, Date, Size - so anchoring there reports a loop bound
    /// of 4 for a folder of 31 files. The row is the iteration unit, and what
    /// identifies a row is that its parent is a table.
    static func enumerable(role: String, parentRole: String, siblings: Int) -> Bool {
        if fixedContainerRoles.contains(parentRole) { return false }
        if collectionContainerRoles.contains(parentRole) { return true }
        // Web content rarely uses table roles. A run of same-role links under
        // one parent is the shape a results list actually takes in Safari;
        // three is enough to be a list rather than a pair of buttons.
        if siblings >= 3, role == "AXLink" || role == "AXRow" { return true }
        return false
    }
}

/// A number Handoff could read on some window, with where it read it. Captured
/// when a person types a short value that they clearly got by LOOKING at
/// another app (the Maps drive time), so it can be re-read on the next pass
/// instead of retyped from memory.
struct ScreenReadout: Sendable, Codable {
    var bundleID: String
    var appName: String
    var rolePath: String
    var role: String
    var text: String
}
