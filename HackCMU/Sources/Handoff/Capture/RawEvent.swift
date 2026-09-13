import CoreGraphics

enum RawKind: UInt8 {
    case keyDown, keyUp, flagsChanged
    case mouseDown, mouseUp, scroll
    case appSwitch, axNotify
}

/// A captured input event, in a form the tap callback can produce without
/// touching the allocator.
///
/// Trivially copyable ON PURPOSE: no String, no CFType, no class references.
/// The tap callback runs on a thread where any ARC traffic, allocation, or
/// lock contention risks blowing the ~1s budget after which macOS silently
/// disables the tap. Everything expensive happens later, on the enrich queue.
struct RawEvent {
    var kind: RawKind = .keyDown
    var buttonOrAxis: UInt8 = 0
    var clickState: UInt8 = 0        // .mouseEventClickState: 1 = single, 2 = double
    var charCount: UInt8 = 0
    var keyCode: UInt16 = 0
    var isAutoRepeat: Bool = false
    var secureInput: Bool = false
    var flags: UInt64 = 0            // CGEventFlags.rawValue
    var pid: Int32 = 0
    var x: Float32 = 0
    var y: Float32 = 0               // global, TOP-LEFT origin - same space AX uses
    var scrollDelta: Int32 = 0
    /// CLOCK_UPTIME_RAW nanoseconds. CGEvent.timestamp is in mach ticks; we
    /// normalize at capture so every later stage speaks one unit.
    var hostTime: UInt64 = 0
    /// Up to 4 UTF-16 units of typed text. Longer input sets charCount = 255.
    var chars: (UInt16, UInt16, UInt16, UInt16) = (0, 0, 0, 0)
}
