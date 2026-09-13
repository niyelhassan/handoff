// Renders the suggestion window to PNGs, light and dark.
//
// Through a real NSWindow + cacheDisplay rather than SwiftUI's ImageRenderer:
// ImageRenderer cannot rasterize AppKit-backed controls and leaves placeholder
// blocks where the buttons should be, which is exactly the part worth looking
// at. Needs a logged-in GUI session; needs no Screen Recording grant.

import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let controller = SuggestionController()
    controller.showSample()

    // Guards on the two window settings that silently break text input. Both
    // were found live, not by reading: a borderless window reports a focused
    // text field and then drops every keystroke, and a window that cannot
    // become main never hands it first responder in the first place.
    let probe = SuggestionPanel(rootView: SuggestionView(controller: controller))
    var windowFailures = 0
    func expect(_ ok: Bool, _ what: String) {
        print((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { windowFailures += 1 }
    }
    print("== suggestion window ==")
    // NSWindow.StyleMask.borderless is the EMPTY option set, so `contains`
    // reports true for every mask. Non-emptiness is the real check.
    expect(probe.styleMask.rawValue != 0,
           "not borderless - borderless windows cannot host a field editor")
    expect(probe.styleMask.contains(.titled), "titled, with the chrome hidden")
    expect(probe.canBecomeKey, "can become key")
    expect(probe.canBecomeMain, "can become main - required for first responder")
    expect(!probe.isMovableByWindowBackground,
           "not movable by background - it competes with the controls for clicks")
    expect(probe.titleVisibility == .hidden && probe.titlebarAppearsTransparent,
           "and still looks chromeless")
    probe.close()
    if windowFailures > 0 {
        print("\n\(windowFailures) WINDOW FAILURE(S)")
        exit(1)
    }
    print("")

    // Both stages: the suggestion, and the confirmation that has to be passed
    // before anything is replayed.
    // Three states worth looking at: the suggestion, the confirmation when the
    // task ends in something irreversible, and the confirmation when it does
    // not (which is where the run-count field lives).
    enum Shot { case suggest, confirmCommit, confirmCount }
    var shots: [(String, NSAppearance, Shot)] = []
    for (name, ap) in [("light", NSAppearance(named: .aqua)!),
                       ("dark", NSAppearance(named: .darkAqua)!)] {
        shots.append(("\(name)", ap, .suggest))
        shots.append(("\(name)-confirm", ap, .confirmCommit))
        shots.append(("\(name)-count", ap, .confirmCount))
    }

    for (name, appearance, shot) in shots {
        NSApp.appearance = appearance
        switch shot {
        case .suggest:
            controller.backToSuggestion()
        case .confirmCommit:
            controller.stopBeforeCommit = true
            controller.accept()
        case .confirmCount:
            controller.stopBeforeCommit = false
            controller.accept()
        }

        // Through a real window + cacheDisplay, so AppKit-backed controls
        // (.bordered, .borderedProminent) actually draw. ImageRenderer cannot
        // rasterize those and leaves placeholder blocks.
        let host = NSHostingView(rootView: SuggestionView(controller: controller))
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)

        let win = NSWindow(contentRect: host.frame,
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = appearance
        win.isOpaque = false
        win.backgroundColor = .clear
        win.contentView = host
        win.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("no rep for \(name)"); continue
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("no png for \(name)"); continue
        }
        let path = CommandLine.arguments[1] + "/live-\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)  fittingSize \(Int(size.width))x\(Int(size.height))pt")
    }
}
