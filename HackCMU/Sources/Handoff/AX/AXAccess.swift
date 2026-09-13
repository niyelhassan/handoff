import ApplicationServices
import Foundation

/// Thin, non-throwing wrappers over the AXUIElement C API.
///
/// Every call here is synchronous IPC into another process. NONE of it may run
/// on the event tap thread - a callback that overruns ~1s gets the tap silently
/// disabled. The enrich queue is the only correct place.
enum AX {

    /// Deliberately short. The default is 6 seconds, which for an unresponsive
    /// app would stall the enrich queue long enough to back up the ring. A
    /// click we cannot resolve in a quarter second is one we fall back on.
    static let timeout: Float = 0.25

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else {
            return nil
        }
        return v
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ el: AXUIElement, _ name: String) -> Int? {
        (attr(el, name) as? NSNumber)?.intValue
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name) else { return nil }
        guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (attr(el, name) as? [AXUIElement]) ?? []
    }

    /// The element's AXValue as a string, if it has one - some readouts live
    /// there rather than in the title.
    static func stringValue(_ el: AXUIElement) -> String? {
        string(el, kAXValueAttribute as String)
    }

    static func role(_ el: AXUIElement) -> String {
        string(el, kAXRoleAttribute as String) ?? "?"
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        elements(el, kAXChildrenAttribute as String)
    }

    static func parent(_ el: AXUIElement) -> AXUIElement? {
        element(el, kAXParentAttribute as String)
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var v: CFArray?
        guard AXUIElementCopyActionNames(el, &v) == .success else { return [] }
        return (v as? [String]) ?? []
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }

    static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else {
            return nil
        }
        var p = CGPoint.zero
        guard AXValueGetValue((v as! AXValue), .cgPoint, &p) else { return nil }
        return p
    }

    static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else {
            return nil
        }
        var sz = CGSize.zero
        guard AXValueGetValue((v as! AXValue), .cgSize, &sz) else { return nil }
        return sz
    }

    /// The element under a point, in global top-left screen coordinates - the
    /// same space `RawEvent.x/y` already uses.
    static func hitTest(pid: pid_t, x: Float, y: Float) -> AXUIElement? {
        var out: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app(pid), x, y, &out)
        guard err == .success else { return nil }
        return out
    }

    /// A title that is worth matching on.
    ///
    /// Falls through AXTitle -> AXDescription -> AXValue because coverage is
    /// wildly uneven across apps (the probe measured title/description at a
    /// small minority of nodes), and rejects anything long enough to be content
    /// rather than a label - a whole paragraph of AXValue is not a name.
    static func stableTitle(_ el: AXUIElement) -> String? {
        for key in [kAXTitleAttribute as String,
                    kAXDescriptionAttribute as String,
                    kAXValueAttribute as String] {
            guard let s = string(el, key) else { continue }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.count > 80 { continue }
            return t
        }
        return nil
    }
}
