import AppKit
import ApplicationServices
import Foundation

/// `./handoff axdump` - reports what the resolver sees inside live windows.
///
/// The Phase 2 counterpart to the Phase 0b probe, and the same reasoning: the
/// quality of AX data is a property of each app, not something a build can tell
/// you. It samples a column of points down a window and prints what each one
/// resolves to, WITHOUT synthesizing a single event - nothing is clicked,
/// selected, or changed.
///
/// The two things to look for: whether rows come back `enumerable` with
/// sensible ordinals, and whether `of N` is the real item count. Those are
/// exactly what the loop bound depends on.
func AXResolver_canonical(_ u: String) -> String { Normalizer.canonicalURL(u) }

enum AXDump {

    static func run(resolver: AXResolver, to path: String) {
        var out = "=== Handoff AX target dump ===\n"
        out += "\(Date())\n\n"

        guard AXIsProcessTrusted() else {
            out += "NOT TRUSTED for Accessibility. Grant Handoff in System Settings.\n"
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }

        for bundleID in ["com.apple.finder", "com.apple.Safari"] {
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first else {
                out += "\(bundleID): NOT RUNNING - skipped\n\n"
                continue
            }
            out += "\(app.localizedName ?? bundleID) (pid \(app.processIdentifier))\n"
            out += dump(app: app, resolver: resolver) + "\n"
        }

        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func dump(app: NSRunningApplication,
                             resolver: AXResolver) -> String {
        let pid = app.processIdentifier
        let appEl = AX.app(pid)
        let windows = AX.elements(appEl, kAXWindowsAttribute as String)
        guard let win = windows.first else { return "    no windows\n" }

        guard let origin = AX.point(win, kAXPositionAttribute as String),
              let size = AX.size(win, kAXSizeAttribute as String),
              size.width > 50, size.height > 50 else {
            return "    window has no usable frame\n"
        }

        var out = "    window \"\(AX.stableTitle(win) ?? "-")\" "
        out += "\(Int(size.width))x\(Int(size.height)) at "
        out += "\(Int(origin.x)),\(Int(origin.y))\n"

        // A column a third of the way in, stepping down past the toolbar. In
        // Finder that walks the file list; in Safari it walks page content.
        let x = Float(origin.x + size.width * 0.33)
        var y = Float(origin.y + 90)
        let bottom = Float(origin.y + size.height - 30)
        let step: Float = 22

        var seen = Set<String>()
        var samples = 0
        let started = Date()

        while y < bottom, samples < 24 {
            defer { y += step }
            guard let t = resolver.resolve(pid: pid, x: x, y: y) else { continue }
            // Consecutive samples inside one tall element are not news.
            let key = "\(t.rolePath)#\(t.ordinal)#\(t.title ?? "")"
            guard seen.insert(key).inserted else { continue }
            samples += 1

            out += "      y=\(Int(y))  \(t.role)"
            if let s = t.subrole { out += "/\(s)" }
            out += t.isEnumerable
                ? "  ENUMERABLE item \(t.ordinal + 1) of \(t.siblingCount)"
                : "  fixed"
            out += "\n"
            out += "        title: \(t.title ?? "-")"
            if let n = t.itemName { out += "   item name: \(n)" }
            out += "\n"
            out += "        path : \(t.rolePath)\n"
            if let c = t.containerRole {
                out += "        in   : \(c) \"\(t.containerTitle ?? "-")\"\n"
            }
            out += "        press: \(t.canPress ? "yes" : "NO - coordinate replay only")"
            out += "   actions: \(t.actions.isEmpty ? "none" : t.actions.joined(separator: ","))\n"
            if let u = t.url { out += "        url  : \(u)\n" }
            if let id = t.identifier { out += "        axid : \(id)\n" }
        }

        // The read-and-retype source check: what numbers can Handoff read off
        // this window without clicking anything? (Maps' drive time lives here.)
        let readouts = resolver.numericReadouts(pid: pid, bundleID: app.bundleIdentifier ?? "",
                                                appName: app.localizedName ?? "")
        if !readouts.isEmpty {
            out += "    numeric readouts (\(readouts.count)):\n"
            for r in readouts.prefix(10) {
                out += "      \"\(r.text)\"  [\(r.role)]\n"
            }
        }

        // Tab-aware read: the active web tab's URL and the numbers under it.
        if let ctx = resolver.activeBrowserContext(pid: pid,
                bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "") {
            out += "    active tab: \(AXResolver_canonical(ctx.url))\n"
            for r in ctx.readouts.prefix(8) { out += "      web# \"\(r.text)\"\n" }
        }

        let elapsed = Date().timeIntervalSince(started)
        out += String(format: "    %d distinct elements, %.0fms total (%.1fms per hit test)\n",
                      samples, elapsed * 1000,
                      samples > 0 ? elapsed * 1000 / Double(samples) : 0)
        if samples == 0 { out += "    ** nothing resolved - window may be empty or occluded\n" }
        return out
    }
}
