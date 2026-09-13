import AppKit
import ApplicationServices

// Phase 0b. Answers three questions before we build anything on top:
//   1. Which target apps expose a usable AX tree at all?
//   2. Is kAXIdentifier ever populated, or is rolePath the only locator?
//   3. Can we read the browser URL (for TaskContext) from AXWebArea's AXURL,
//      or must we fall back to the omnibox?

let TIMEOUT: Float = 0.5

func str(_ el: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    if let u = v as? URL { return u.absoluteString }
    return nil
}

func children(_ el: AXUIElement, _ attr: String = kAXChildrenAttribute) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return [] }
    return (v as? [AXUIElement]) ?? []
}

func attrNames(_ el: AXUIElement) -> [String] {
    var v: CFArray?
    guard AXUIElementCopyAttributeNames(el, &v) == .success else { return [] }
    return (v as? [String]) ?? []
}

func actionNames(_ el: AXUIElement) -> [String] {
    var v: CFArray?
    guard AXUIElementCopyActionNames(el, &v) == .success else { return [] }
    return (v as? [String]) ?? []
}

struct Stats {
    var nodes = 0, withIdentifier = 0, withTitle = 0, actionable = 0, maxDepth = 0
    var roles: [String: Int] = [:]
    var webAreaURL: String?
    var omniboxURL: String?
}

func walk(_ el: AXUIElement, depth: Int, budget: inout Int, s: inout Stats) {
    guard budget > 0, depth < 14 else { return }
    budget -= 1
    s.nodes += 1
    s.maxDepth = max(s.maxDepth, depth)

    let role = str(el, kAXRoleAttribute) ?? "?"
    s.roles[role, default: 0] += 1
    if let id = str(el, kAXIdentifierAttribute), !id.isEmpty { s.withIdentifier += 1 }
    if let t = str(el, kAXTitleAttribute) ?? str(el, kAXDescriptionAttribute), !t.isEmpty { s.withTitle += 1 }
    let acts = actionNames(el).filter { $0 != kAXShowMenuAction && $0 != "AXScrollToVisible" }
    if !acts.isEmpty { s.actionable += 1 }

    // The two candidate sources for browser TaskContext.
    if role == "AXWebArea", s.webAreaURL == nil {
        s.webAreaURL = str(el, "AXURL") ?? str(el, kAXValueAttribute)
    }
    if s.omniboxURL == nil, role == "AXTextField" || role == "AXComboBox" {
        let hint = ((str(el, kAXDescriptionAttribute) ?? "") + " " +
                    (str(el, kAXTitleAttribute) ?? "") + " " +
                    (str(el, kAXIdentifierAttribute) ?? "")).lowercased()
        if hint.contains("address") || hint.contains("url") || hint.contains("search")
            || hint.contains("location") {
            if let v = str(el, kAXValueAttribute), !v.isEmpty { s.omniboxURL = v }
        }
    }
    for c in children(el) { walk(c, depth: depth + 1, budget: &budget, s: &s) }
}

func probe(_ app: NSRunningApplication, forceAX: Bool) -> Stats? {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, TIMEOUT)
    if forceAX {
        // Chromium and Electron expose a stub tree until one of these is set.
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 1.2)   // tree construction is async
    }
    let windows = children(el, kAXWindowsAttribute)
    guard !windows.isEmpty else { return nil }
    var s = Stats(); var budget = 4000
    let t0 = Date()
    for w in windows.prefix(2) { walk(w, depth: 0, budget: &budget, s: &s) }
    emit(String(format: "    walk took %.2fs, budget left %d", Date().timeIntervalSince(t0), budget))
    return s
}

// MARK: - main

// Output goes to a file, not stdout: TCC attributes a process to whoever
// launched it, so the probe must be started with `open` (which detaches it
// from the terminal and therefore from the terminal's stdout).
let outPath = CommandLine.arguments.dropFirst().first
    ?? "/tmp/handoff-probe.txt"
var report = ""
func emit(_ line: String = "") { report += line + "\n" }
func flush() { try? report.write(toFile: outPath, atomically: true, encoding: .utf8) }

if !AXIsProcessTrusted() {
    // Prompts only when TCC has no record yet; otherwise returns false silently.
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    // Give the user a window to click Allow, then re-check.
    for _ in 0..<60 {
        if AXIsProcessTrusted() { break }
        Thread.sleep(forTimeInterval: 1.0)
    }
}
guard AXIsProcessTrusted() else {
    emit("NOT TRUSTED for Accessibility after 60s.")
    emit("Grant HandoffProbe in System Settings > Privacy & Security > Accessibility,")
    emit("then run ./handoff probe again.")
    flush(); exit(1)
}

let targets = [
    ("com.google.Chrome",  "Chrome",  true),
    ("com.apple.Safari",   "Safari",  false),
    ("com.apple.Terminal", "Terminal", false),
    ("com.apple.finder",   "Finder",  false),
]

emit("=== Handoff AX probe ===")
for (bundleID, name, forceAX) in targets {
    guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
        emit("\(name): NOT RUNNING - skipped\n"); continue
    }
    emit("\(name) (pid \(app.processIdentifier))\(forceAX ? " [forcing AX]" : "")")
    guard let s = probe(app, forceAX: forceAX) else {
        emit("    NO WINDOWS / no AX tree\n"); continue
    }
    let idPct = s.nodes > 0 ? s.withIdentifier * 100 / s.nodes : 0
    let tiPct = s.nodes > 0 ? s.withTitle * 100 / s.nodes : 0
    emit("    nodes=\(s.nodes) depth=\(s.maxDepth) actionable=\(s.actionable)")
    emit("    kAXIdentifier populated: \(idPct)%   title/desc populated: \(tiPct)%")
    let top = s.roles.sorted { $0.value > $1.value }.prefix(6)
        .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    emit("    top roles: \(top)")
    if bundleID.contains("Chrome") || bundleID.contains("Safari") {
        emit("    AXWebArea AXURL: \(s.webAreaURL ?? "** NOT FOUND **")")
        emit("    omnibox value  : \(s.omniboxURL ?? "** NOT FOUND **")")
    }
    // Node count alone is misleading for browsers: the toolbar and tab strip
    // alone clear 40 nodes while the page itself exposes nothing. Require real
    // content density before calling a browser usable.
    let isBrowser = bundleID.contains("Chrome") || bundleID.contains("Safari")
    let contentNodes = (s.roles["AXLink"] ?? 0) + (s.roles["AXStaticText"] ?? 0)
        + (s.roles["AXCell"] ?? 0) + (s.roles["AXRow"] ?? 0)
    let verdict: String
    switch true {
    case s.nodes <= 5:                  verdict = "UNUSABLE - no tree"
    case s.actionable == 0:             verdict = "READ-ONLY - replay must use coordinates"
    case isBrowser && s.webAreaURL == nil:
        verdict = "CHROME-ONLY - no web content tree (URL still readable via omnibox)"
    case isBrowser && contentNodes < 50:
        verdict = "DEGRADED - stub content tree (\(contentNodes) content nodes); expect coordinate fallback in page"
    case s.nodes <= 40:                 verdict = "THIN - likely coordinate fallback"
    default:                            verdict = "USABLE"
    }
    emit("    VERDICT: \(verdict)\n")
}

flush()
