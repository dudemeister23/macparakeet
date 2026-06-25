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

    public init() {}

    /// Mark dictation as holding/needing the engine (true) or done (false).
    public func setDictationActive(_ active: Bool) {
        lock.lock()
        dictationActive = active
        let toResume: [CheckedContinuation<Void, Never>]
        if active {
            toResume = []
        } else {
            toResume = waiters
            waiters.removeAll()
        }
        lock.unlock()
        for continuation in toResume {
            continuation.resume()
        }
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
