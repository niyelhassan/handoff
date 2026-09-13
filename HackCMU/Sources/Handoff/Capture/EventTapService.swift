import Carbon
import CoreGraphics
import Foundation
import Synchronization

// MUST be file-scope and `nonisolated(unsafe)`. Swift infers @MainActor for a
// file-scope `let` and then refuses to hand it to a nonisolated C API. And a C
// function pointer cannot capture context, so `self` arrives via userInfo.
nonisolated(unsafe) let handoffTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let svc = Unmanaged<EventTapService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        svc.handleDisabled(type)
        return nil
    }
    svc.ingest(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

/// Owns the global event tap and the dedicated thread it runs on.
///
/// The callback does exactly one thing - copy a POD struct into a ring - and
/// nothing else. No Accessibility calls, ever: AX is synchronous IPC into
/// another process and can block for seconds, and a callback that overruns
/// ~1s causes macOS to silently disable the tap.
final class EventTapService: @unchecked Sendable {

    let ring = RawEventRing()

    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var activityToken: NSObjectProtocol?
    private var reenableCount = 0
    private var lastReenable: UInt64 = 0

    /// Set when the tap could not be created - almost always a missing
    /// Input Monitoring grant.
    let failed = Atomic<Bool>(false)
    let running = Atomic<Bool>(false)
    /// Times macOS disabled our tap and we revived it. Surfaced in the UI
    /// because a climbing number means the callback is doing too much work.
    let reenables = Atomic<UInt64>(0)

    /// True while Handoff is driving the machine itself.
    let replayActive = Atomic<Bool>(false)
    /// Set the instant a REAL event arrives during replay. This is the stop
    /// button: the user does not have to find a window, they just type.
    let userInterrupted = Atomic<Bool>(false)
    /// What tripped it - the CGEventType raw value - so a spurious interrupt
    /// can be identified rather than guessed at.
    let interruptCause = Atomic<UInt32>(0)

    private static let mask: CGEventMask = {
        // Built in a loop rather than as one big `|` chain: the type checker
        // times out on a 10-term shift-and-or expression of CGEventMask.
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .scrollWheel,
        ]
        var m: CGEventMask = 0
        for t in types { m |= CGEventMask(1) << CGEventMask(t.rawValue) }
        return m
    }()
        // Deliberately NOT mouseMoved/dragged: thousands per second, and almost
        // no semantic value for detecting repeated tasks.

    // MARK: - Lifecycle

    func start() {
        guard !running.load(ordering: .acquiring) else { return }
        // Without this, App Nap can throttle a background LSUIElement app
        // enough that the callback overruns its budget under load.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Handoff input capture")

        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "com.hackcmu.handoff.tap"
        t.qualityOfService = .userInteractive
        t.stackSize = 512 * 1024
        t.start()
    }

    /// Tears the tap down so it can be rebuilt. Required after an Input
    /// Monitoring grant: an existing tap stays permanently dead even though
    /// the permission now reads as granted.
    func stop() {
        if let runLoop { CFRunLoopStop(runLoop) }
        running.store(false, ordering: .releasing)
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    func restart() {
        stop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.port = nil
            self?.start()
        }
    }

    private func threadMain() {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.mask,
            callback: handoffTapCallback,
            // passUnretained: the AppDelegate owns us for the process lifetime.
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            failed.store(true, ordering: .releasing)
            return
        }

        self.port = port
        self.runLoop = CFRunLoopGetCurrent()
        failed.store(false, ordering: .releasing)
        running.store(true, ordering: .releasing)

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(runLoop, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        // A tap can also die SILENTLY - permission revoked, port invalidated -
        // without ever delivering a .tapDisabledBy* event. Poll for that.
        let timer = CFRunLoopTimerCreateWithHandler(
            nil, CFAbsoluteTimeGetCurrent() + 2, 2, 0, 0
        ) { [weak self] _ in self?.watchdogTick() }
        CFRunLoopAddTimer(runLoop, timer, .commonModes)

        CFRunLoopRun()

        // Loop stopped: unwind.
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        running.store(false, ordering: .releasing)
    }

    // MARK: - Tap thread callbacks

    /// Called ON THE TAP THREAD.
    func handleDisabled(_ type: CGEventType) {
        guard let port else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if now &- lastReenable < 1_000_000_000 {
            reenableCount += 1
            if reenableCount > 5 {
                // Thrashing. Rebuilding is better than an infinite re-enable loop.
                reenableCount = 0
                DispatchQueue.global().async { [weak self] in self?.restart() }
                return
            }
        } else {
            reenableCount = 0
        }
        lastReenable = now
        reenables.wrappingAdd(1, ordering: .relaxed)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func watchdogTick() {
        guard let port else { return }
        if !CGEvent.tapIsEnabled(tap: port) {
            CGEvent.tapEnable(tap: port, enable: true)
            reenables.wrappingAdd(1, ordering: .relaxed)
            if !CGEvent.tapIsEnabled(tap: port) {
                DispatchQueue.global().async { [weak self] in self?.restart() }
            }
        }
    }

    /// Called ON THE TAP THREAD, once per event. Everything here is an
    /// in-process CoreGraphics accessor - no IPC, no allocation, no ARC.
    @inline(__always)
    func ingest(type: CGEventType, event: CGEvent) {
        // Handoff's own synthesized events carry a marker. Dropping them here,
        // at the earliest possible point, does two necessary things: it stops
        // a replay from being detected as a brand new loop, and it keeps the
        // interrupt check below from treating our own clicks as the user
        // reaching for the keyboard.
        if event.getIntegerValueField(.eventSourceUserData) == ReplayMarker.value {
            return
        }
        // Only a deliberate act counts as taking over. Scroll wheels and
        // modifier changes are excluded on purpose: a hand resting on a
        // trackpad emits both, and an abort that fires when nobody touched
        // anything is worse than one that needs an actual keypress.
        if replayActive.load(ordering: .relaxed) {
            switch type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
                interruptCause.store(type.rawValue, ordering: .relaxed)
                userInterrupted.store(true, ordering: .releasing)
            default:
                break
            }
        }

        var e = RawEvent()
        e.hostTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        e.pid = Int32(event.getIntegerValueField(.eventTargetUnixProcessID))
        e.flags = event.flags.rawValue

        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            e.kind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .flagsChanged)
            e.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            e.isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if type == .keyDown {
                // Secure input is on while a password field has focus. macOS
                // already withholds the characters from taps in that state, but
                // recording the fact is what lets the normalizer still emit a
                // "typed something" step - so a password does not silently
                // punch a hole in an otherwise-detectable loop. Reads a cached
                // window-server flag; no IPC, safe in the callback.
                e.secureInput = IsSecureEventInputEnabled()
                if !e.secureInput {
                    var n = 0
                    withUnsafeMutableBytes(of: &e.chars) { raw in
                        guard let base = raw.baseAddress?.assumingMemoryBound(to: UniChar.self)
                        else { return }
                        event.keyboardGetUnicodeString(
                            maxStringLength: 4, actualStringLength: &n, unicodeString: base)
                    }
                    e.charCount = n > 4 ? 255 : UInt8(n)
                }
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)
            e.kind = isDown ? .mouseDown : .mouseUp
            e.buttonOrAxis = UInt8(event.getIntegerValueField(.mouseEventButtonNumber))
            e.clickState = UInt8(clamping: event.getIntegerValueField(.mouseEventClickState))
            let p = event.location    // already global, top-left origin
            e.x = Float32(p.x); e.y = Float32(p.y)

        case .scrollWheel:
            e.kind = .scroll
            e.scrollDelta = Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let p = event.location
            e.x = Float32(p.x); e.y = Float32(p.y)

        default:
            return
        }

        ring.write(e)
    }
}
