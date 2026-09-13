import Foundation

/// Normalization + detection, as one unit the capture layer can hand events to.
///
/// ENRICH QUEUE ONLY - single-threaded by construction, with no locks anywhere
/// inside it. `CaptureCoordinator` is `@MainActor`, so this deliberately is not
/// a member of it: keeping the pipeline a separate, plainly non-isolated object
/// makes the threading rule something the type says out loud rather than
/// something a comment promises.
///
/// The callbacks fire on the enrich queue. Both hop to the main actor.
final class DetectionPipeline: @unchecked Sendable {

    /// Fired for every atom, in order. Debug readout only.
    var onAtom: (@Sendable (Atom) -> Void)?
    /// Fired whenever the stream currently looks like a loop - which is on
    /// every atom once one is running, not once per loop. Rate limiting and
    /// "have we already said this" live in the controller.
    var onCandidate: (@Sendable (LoopCandidate) -> Void)?
    /// Fired when the last few steps are the OPENING of a task Handoff has seen
    /// before. No second and third pass required - the evidence was gathered
    /// the last time.
    var onRecognised: (@Sendable (StoredPattern, Int, [Atom]) -> Void)?

    let library: PatternLibrary

    let detector = LoopDetector()
    private var normalizer: Normalizer!

    /// Diagnostic sink, forwarded to the normalizer's web tracing.
    var trace: ((String) -> Void)? {
        didSet { normalizer.trace = trace }
    }

    init(resolver: TargetResolver? = nil,
         library: PatternLibrary = PatternLibrary()) {
        self.library = library
        normalizer = Normalizer(resolver: resolver) { [weak self] atom in
            self?.handle(atom)
        }
    }

    func consume(_ e: RawEvent) { normalizer.consume(e) }

    /// Must be called even on empty drains: a run of typing ends by the typist
    /// pausing, which by definition produces no event to notice it with.
    func tick(now: UInt64) { normalizer.tick(now: now) }

    func reset() { normalizer.reset(); detector.reset(); resetTail() }

    /// The last handful of signal atoms, for prefix matching.
    private var tail: [Atom] = []
    /// Which pattern the current run of steps was already reported as, so a
    /// recognition fires once per pass rather than once per step.
    private var reportedPrefix: UInt64?

    private func handle(_ atom: Atom) {
        onAtom?(atom)

        // A loop happening right now always wins: it is direct evidence, where
        // recognition is a claim about the past.
        if let c = detector.ingest(atom) {
            reportedPrefix = nil
            onCandidate?(c)
            return
        }

        guard atom.isSignal else { return }
        tail.append(atom)
        if tail.count > 24 { tail.removeFirst(tail.count - 24) }

        if let (pattern, matched) = library.recognisePrefix(in: tail) {
            guard reportedPrefix != pattern.id else { return }
            reportedPrefix = pattern.id
            onRecognised?(pattern, matched, Array(tail.suffix(matched)))
        } else {
            reportedPrefix = nil
        }
    }

    func resetTail() { tail.removeAll(keepingCapacity: true); reportedPrefix = nil }
}
