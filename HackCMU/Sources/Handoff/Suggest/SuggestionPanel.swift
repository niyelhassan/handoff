import AppKit
import SwiftUI

/// A floating panel that can be clicked without Handoff becoming the active app.
///
/// This is the one piece of UI that appears while the user is working in
/// someone else's app, so the activation rules are not cosmetic:
///
///   - It is ordered in with `orderFrontRegardless()`, never
///     `makeKeyAndOrderFront(_:)`. That is what keeps a suggestion from
///     stealing focus: it appears beside the work without interrupting it, and
///     `kAXFocusedApplication` keeps naming the app the user is actually in.
///   - Focus is taken only when the user has engaged - the confirmation stage,
///     which has editable fields - and handed straight back afterwards. See
///     `SuggestionController.takeFocus`.
///   - `canJoinAllSpaces` + `fullScreenAuxiliary` because a repeated task is
///     very often being done in a full-screen window, and a suggestion on
///     another Space is a suggestion nobody sees.
@MainActor
final class SuggestionPanel: NSPanel {

    private let margin: CGFloat = 18

    init<Content: View>(rootView: Content) {
        // NOT `.nonactivatingPanel`. That mask opts the window out of
        // activation entirely, which also makes it impossible to ever type
        // into - and the confirmation stage has fields the user must be able
        // to edit. What the mask was actually protecting is achieved by HOW
        // the panel is shown: `orderFrontRegardless()` puts it on screen
        // without taking focus. Focus is then taken deliberately, and only for
        // the stages that need it.
        // `.titled` with the chrome hidden, NOT `.borderless`. A borderless
        // window looks identical and is subtly broken for text: AppKit will not
        // install a field editor in one, so a SwiftUI TextField inside reads as
        // focused, receives nothing, and silently drops every keystroke.
        // Measured that the hard way. Titled-but-transparent behaves like a
        // real window and looks the same.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Deliberately NOT movable by background: it competes with the
        // SwiftUI controls for mouse-down and the fields stop taking clicks.
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow

        // A hosting CONTROLLER, not a bare hosting view: this is what wires
        // SwiftUI into AppKit's responder chain, and without it a TextField in
        // the content can never become first responder no matter what the
        // window allows.
        let host = FirstMouseHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        let controller = NSViewController()
        controller.view = host
        contentViewController = controller
        initialFirstResponder = host
        // The card sizes itself from its content; the panel follows.
        setContentSize(host.fittingSize)
    }

    /// Required, not optional: the confirmation stage has text fields, and a
    /// window that cannot become key cannot receive a keystroke. `.nonactivating`
    /// still means showing the panel does not steal focus - the controller
    /// activates deliberately, for the two stages that need it, and hands focus
    /// back afterwards.
    override var canBecomeKey: Bool { true }
    /// Also required. A window that cannot become main will not hand first
    /// responder to a text field, so the name field stayed unfocused and every
    /// keystroke went to whatever was behind it - measured, not theorised.
    override var canBecomeMain: Bool { true }

    /// Hands first responder to the hosted SwiftUI content so a field inside
    /// it can take the keyboard.
    func focusContent() {
        guard let content = contentView else { return }
        makeFirstResponder(content)
    }

    func showBottomTrailing() {
        let screen = Self.screenUnderMouse()
        let visible = screen.visibleFrame
        let size = (contentView?.fittingSize).map { NSSize(width: max($0.width, 340),
                                                           height: $0.height) }
            ?? frame.size
        setContentSize(size)

        let target = NSRect(x: visible.maxX - size.width - margin,
                            y: visible.minY + margin,
                            width: size.width, height: size.height)
        // Start slightly low and transparent so it reads as arriving rather
        // than as something that was always there and went unnoticed.
        setFrame(target.offsetBy(dx: 0, dy: -14), display: false)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    /// The card's height depends on its content, and its content changes while
    /// it is on screen: the pass count climbs, and a step that had looked
    /// constant can start varying, adding a line. Without this the window keeps
    /// its original height and quietly clips the buttons off the bottom.
    func refit() {
        guard let host = contentView else { return }
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        guard fitted.height > 0, abs(fitted.height - frame.height) > 0.5 else { return }
        // Pinned bottom-right, so it grows upward and stays where the user last
        // saw it - including after they have dragged it somewhere else.
        let f = frame
        setFrame(NSRect(x: f.maxX - fitted.width, y: f.minY,
                        width: fitted.width, height: fitted.height),
                 display: true, animate: false)
    }

    func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            orderOut(nil)
            // Breaks the panel -> hosting view -> controller -> panel cycle.
            contentView = nil
            close()
        }
    }

    private static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

/// Without this, the first click on the panel is spent making it key and the
/// button under the pointer never fires - so every answer would take two
/// clicks, and the first one would look like a bug.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Without this the hosting view is skipped by the responder chain, so a
    /// SwiftUI TextField inside it can never become first responder and the
    /// window keeps focus to itself.
    override var acceptsFirstResponder: Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
