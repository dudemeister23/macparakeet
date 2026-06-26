import Foundation

/// Lets interactive dictation take priority over long-running background STT
/// (e.g. per-turn "Detect speakers") on a single serial engine like Cohere.
///
/// Dictation marks itself active while it holds (or is about to need) the engine;
/// background work awaits `awaitDictationIdle()` between units so it yields the
/// engine and the dictation can transcribe. Active is set synchronously from the
/// dictation state machine, so the signal lands before the engine is contended;
/// the wait is async.
public final class STTEnginePriorityCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var dictationActive = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Handlers that cancel an in-flight, preemptible background unit (a
    /// per-turn Cohere span) the instant dictation needs the engine. Keyed so a
    /// worker can unregister its own handler when its unit finishes.
    private var preemptHandlers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// Mark dictation as holding/needing the engine (true) or done (false).
    ///
    /// Going active both blocks future `awaitDictationIdle()` callers *and*
    /// fires every registered preemption handler, so an in-flight background
    /// span yields the single serial engine immediately instead of making the
    /// dictation wait out the whole run.
    public func setDictationActive(_ active: Bool) {
        lock.lock()
        dictationActive = active
        let toResume: [CheckedContinuation<Void, Never>]
        let toPreempt: [@Sendable () -> Void]
        if active {
            toResume = []
            toPreempt = Array(preemptHandlers.values)
        } else {
            toResume = waiters
            waiters.removeAll()
            toPreempt = []
        }
        lock.unlock()
        for continuation in toResume {
            continuation.resume()
        }
        for preempt in toPreempt {
            preempt()
        }
    }

    /// Register a handler that cancels the caller's in-flight background unit
    /// when dictation becomes active. If dictation is *already* active the
    /// handler fires synchronously before returning, so a unit started in the
    /// gap right after `awaitDictationIdle()` is still preempted. Returns a
    /// token to pass to `unregisterPreemption` once the unit settles.
    public func registerPreemption(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        preemptHandlers[token] = handler
        let activeNow = dictationActive
        lock.unlock()
        if activeNow {
            handler()
        }
        return token
    }

    public func unregisterPreemption(_ token: UUID) {
        lock.lock()
        preemptHandlers.removeValue(forKey: token)
        lock.unlock()
    }

    public var isDictationActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return dictationActive
    }

    /// Suspend until no dictation is active. Returns immediately when idle.
    public func awaitDictationIdle() async {
        lock.lock()
        if !dictationActive {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !dictationActive {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
