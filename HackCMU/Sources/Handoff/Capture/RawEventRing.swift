import Synchronization

/// Single-producer / single-consumer ring buffer.
///
/// Producer is the event tap thread; consumer is the enrich queue. That
/// invariant is what makes the unsynchronized element access safe, and it is
/// why this is `@unchecked Sendable` rather than lock-guarded: the tap thread
/// must never block.
///
/// On overflow we drop the NEWEST event and count it, rather than overwriting
/// the oldest. A detector that sees a truncated-but-contiguous history is
/// correct-but-incomplete; one that sees a history with a hole punched in the
/// middle would silently mis-measure periods.
final class RawEventRing: @unchecked Sendable {
    private let mask: UInt64
    private let buf: UnsafeMutablePointer<RawEvent>
    private let head = Atomic<UInt64>(0)   // producer cursor
    private let tail = Atomic<UInt64>(0)   // consumer cursor
    private let droppedCount = Atomic<UInt64>(0)

    init(capacityPowerOfTwo n: Int = 4096) {
        precondition(n > 0 && n.nonzeroBitCount == 1, "capacity must be a power of two")
        mask = UInt64(n - 1)
        buf = .allocate(capacity: n)
        buf.initialize(repeating: RawEvent(), count: n)
    }

    deinit {
        buf.deinitialize(count: Int(mask) + 1)
        buf.deallocate()
    }

    var dropped: UInt64 { droppedCount.load(ordering: .relaxed) }
    var pending: UInt64 {
        head.load(ordering: .relaxed) &- tail.load(ordering: .relaxed)
    }

    /// PRODUCER - tap thread only. Wait-free: no allocation, no syscall, no lock.
    @inline(__always)
    func write(_ e: RawEvent) {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h &- t <= mask else {
            droppedCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        buf[Int(h & mask)] = e
        head.store(h &+ 1, ordering: .releasing)   // publishes the element
    }

    /// CONSUMER - enrich queue only.
    @discardableResult
    func drain(max: Int, into out: inout ContiguousArray<RawEvent>) -> Int {
        let h = head.load(ordering: .acquiring)
        var t = tail.load(ordering: .relaxed)
        var n = 0
        while t != h && n < max {
            out.append(buf[Int(t & mask)])
            t &+= 1
            n += 1
        }
        if n > 0 { tail.store(t, ordering: .releasing) }
        return n
    }
}
