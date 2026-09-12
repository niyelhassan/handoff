import AppKit
import ApplicationServices
import ScoutCore

func axValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? { var value: CFTypeRef?; guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }; return value }
func axString(_ element: AXUIElement, _ key: String) -> String { if let value = axValue(element,key) as? String { return value }; if let url = axValue(element,key) as? URL { return url.absoluteString }; return "" }
func axElement(_ element: AXUIElement, _ key: String) -> AXUIElement? { guard let value = axValue(element,key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }; return unsafeBitCast(value,to:AXUIElement.self) }
func axChildren(_ element: AXUIElement) -> [AXUIElement] { axValue(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func axProtected(_ element: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<8 { guard let item = current else { break }; if (axString(item,kAXRoleAttribute)+axString(item,kAXSubroleAttribute)).lowercased().contains("secure") { return true }; current = axElement(item,kAXParentAttribute) }
    return false
}
struct AXNode {
    var element: AXUIElement
    var role: String
    var label: String
    var identifier: String
    var ancestors: [String]
}
@MainActor final class Accessibility {
    var policy: () -> PrivacyPolicy = { PrivacyPolicy() }
    func tree(app: String) throws -> [AXNode] {
        guard AXIsProcessTrusted() else { throw ScoutError.message("Allow Handoff in System Settings → Privacy & Security → Accessibility.") }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier:app).first else { throw ScoutError.message("Open the app used by this step first.") }
        let root = AXUIElementCreateApplication(running.processIdentifier)
        // Prefer the main window: transient popups (autofill suggestions, menus) can briefly become the focused window,
        // and while focus moves an app may report no main or focused window at all. Never fall back to the app root,
        // whose menu bar would exhaust the walk before reaching the content.
        guard let window = Self.contentWindow(root) else { throw ScoutError.message("Open the app’s window used by this step first.") }
        let title = axString(window,kAXTitleAttribute)
        guard policy().permits(app:app,domain:pageURL(root).host ?? "",role:"",window:title) else { throw ScoutError.message("This app or page is excluded from Handoff.") }
        var result: [AXNode] = []; var queue: [(AXUIElement,[String],Int)] = [(window,[],0)]; var index = 0
        while index < queue.count && result.count < 1500 {
            let (e,ancestors,depth) = queue[index]; index += 1
            guard depth < 16, !axProtected(e) else { continue }
            let role = axString(e,kAXRoleAttribute); let label = [axString(e,kAXTitleAttribute),axString(e,kAXDescriptionAttribute),axString(e,kAXHelpAttribute)].first { !$0.isEmpty } ?? ""
            result.append(AXNode(element:e,role:role,label:label,identifier:axString(e,kAXIdentifierAttribute),ancestors:ancestors))
            let path = label.isEmpty ? ancestors : Array((ancestors+[label]).suffix(5))
            queue.append(contentsOf:axChildren(e).prefix(200).map { ($0,path,depth+1) })
        }
        return result
    }
    static let browsers: Set<String> = ["com.apple.Safari","com.apple.SafariTechnologyPreview","com.google.Chrome","com.google.Chrome.canary","com.brave.Browser","com.microsoft.edgemac","org.mozilla.firefox","company.thebrowser.Browser","com.vivaldi.Vivaldi","com.operasoftware.Opera"]
    private static let containers: Set<String> = ["AXWindow","AXGroup","AXSplitGroup","AXScrollArea","AXTabGroup","AXWebArea","AXLayoutArea","AXToolbar","AXSheet","AXDrawer","AXUnknown"]
    /// Reads the current page address of a browser (or the document of a document-based app).
    /// Only container roles are walked and the walk is short, so calling this once per second stays cheap.
    /// The window whose content a routine should read: main, then focused, then the first standard window.
    static func contentWindow(_ root: AXUIElement) -> AXUIElement? {
        if let main = axElement(root,kAXMainWindowAttribute) { return main }
        if let focused = axElement(root,kAXFocusedWindowAttribute), axString(focused,kAXSubroleAttribute) == "AXStandardWindow" { return focused }
        let windows = axValue(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.first { axString($0,kAXSubroleAttribute) == "AXStandardWindow" } ?? windows.first ?? axElement(root,kAXFocusedWindowAttribute)
    }
    func pageURL(_ root: AXUIElement, browser: Bool = true) -> URL {
        let window = Self.contentWindow(root) ?? root
        for item in [root,window] { for attribute in [kAXURLAttribute,"AXDocument"] { let raw = axString(item,attribute); if let url = URL(string:raw), ["https","http"].contains(url.scheme ?? "") { return url } } }
        guard browser else { return URL(string:"about:blank")! }
        var queue = [window]; var i = 0
        while i < queue.count && i < 120 {
            let item = queue[i]; i += 1
            let role = axString(item,kAXRoleAttribute)
            if role == "AXWebArea" { for attribute in [kAXURLAttribute,"AXDocument"] { let raw = axString(item,attribute); if let url = URL(string:raw), ["https","http"].contains(url.scheme ?? "") { return url } }; continue }
            guard Self.containers.contains(role) else { continue }
            queue.append(contentsOf:axChildren(item).prefix(40))
        }
        return URL(string:"about:blank")!
    }
    func resolve(_ target: Target) throws -> AXUIElement {
        let nodes = try tree(app:target.app)
        let scored = nodes.compactMap { node -> (AXNode,Int)? in
            guard target.role.isEmpty || target.role == node.role else { return nil }
            var score = 0
            if !target.identifier.isEmpty && node.identifier == target.identifier { score += 100 }
            if !target.label.isEmpty && node.label == target.label { score += 60 }
            if target.alternates.contains(node.label) && !node.label.isEmpty { score += 45 }
            guard score > 0 else { return nil }
            for ancestor in target.ancestors { guard node.ancestors.contains(ancestor) else { return nil }; score += 10 }
            return (node,score)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { throw ScoutError.message("Could not find ‘\(target.label.isEmpty ? target.identifier : target.label)’. Open the right page, or use Fix.") }
        guard scored.count == 1 || scored[1].1 < best.1 else { throw ScoutError.message("More than one item matches ‘\(target.label)’. The routine needs a more specific description.") }
        return best.0.element
    }
    func snapshot(app: String) throws -> String { try tree(app:app).prefix(300).map { "\($0.role) | \($0.label) | \($0.identifier) | \($0.ancestors.joined(separator:" > "))" }.joined(separator:"\n") }
}
