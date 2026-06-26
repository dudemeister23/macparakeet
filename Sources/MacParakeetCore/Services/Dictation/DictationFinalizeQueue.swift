import Foundation

/// Serial, order-preserving queue for the *finalize* leg of dictation
/// (transcribe → paste/present), decoupled from the interactive capture flow.
///
/// Why this exists: once a capture stops, the user must be free to start the
/// next one immediately — even while the previous transcript is still being
/// produced or pasted. Cohere is a single, batch engine (a second concurrent
/// job throws `engineBusy`), and two transcripts racing into the same cursor
/// would interleave. This queue makes both guarantees **structural** rather
/// than timing-dependent:
///
/// - **At most one transcription runs at a time** — a single worker loop awaits
///   each `transcribe` before starting the next.
/// - **Presentation (paste) happens in strict enqueue order** — which, because
///   session IDs are monotonic, is capture order.
///
/// Nothing is ever dropped: an enqueued job runs unless it is explicitly
/// cancelled by `sessionID`. The actual transcription and presentation are
/// injected, so this type is fully testable headless (no audio, no GUI).
public actor DictationFinalizeQueue {
    /// The result of transcribing a finalize job, decided by the injected
    /// `transcribe` operation. Drives whether `present` pastes or shows a leaf.
    public enum Outcome: Sendable, Equatable {
        case success
        case noSpeech
        case failure(String)
    }

    /// Transcribe one session's captured audio. Must not start its own
    /// concurrent work — the queue guarantees it is the only one in flight.
    private let transcribe: @Sendable (Int) async -> Outcome
    /// Present the finalized session (paste + brief confirmation). Awaited to
    /// completion before the next job is presented, which is what keeps pastes
    /// strictly ordered. Visual dwell (the checkmark) should be fire-and-forget
    /// inside this closure so it doesn't stall the next transcription.
    private let present: @Sendable (Int, Outcome) async -> Void

    private var pending: [Int] = []
    private var cancelled: Set<Int> = []
    private var isDraining = false
    private var inFlightCount = 0

    public init(
        transcribe: @escaping @Sendable (Int) async -> Outcome,
        present: @escaping @Sendable (Int, Outcome) async -> Void
    ) {
        self.transcribe = transcribe
        self.present = present
    }

    /// Number of jobs not yet fully presented (queued + in flight). Drives the
    /// "N pending" overlay affordance.
    public var depth: Int { pending.count + inFlightCount }

    /// Enqueue a captured session for finalize. Returns immediately; the worker
    /// drains in FIFO order.
    public func enqueue(sessionID: Int) {
        pending.append(sessionID)
        startDrainingIfNeeded()
    }

    /// Drop a not-yet-presented job. If it is still queued it is removed before
    /// it runs; if its transcription is already in flight it is marked so its
    /// paste is skipped on completion (the worker is never cancelled mid-engine
    /// to avoid leaving the Core ML pipeline half-finished).
    public func cancel(sessionID: Int) {
        cancelled.insert(sessionID)
        pending.removeAll { $0 == sessionID }
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let sessionID = pending.removeFirst()
            if cancelled.remove(sessionID) != nil { continue }

            inFlightCount += 1
            let outcome = await transcribe(sessionID)

            // A cancel may have arrived while transcribing — skip the paste but
            // let the (already-done) transcription stand.
            if cancelled.remove(sessionID) != nil {
                inFlightCount -= 1
                continue
            }

            await present(sessionID, outcome)
            inFlightCount -= 1
        }
        isDraining = false
    }
}
