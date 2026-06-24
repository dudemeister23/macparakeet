import XCTest

@testable import MacParakeetCore

/// Headless tests for the serial, order-preserving finalize queue. No audio, no
/// GUI — the transcribe/present operations are injected.
final class DictationFinalizeQueueTests: XCTestCase {

    private actor Recorder {
        private(set) var transcribeOrder: [Int] = []
        private(set) var presentOrder: [(id: Int, outcome: DictationFinalizeQueue.Outcome)] = []
        private var concurrentTranscribes = 0
        private(set) var maxConcurrentTranscribes = 0

        func beginTranscribe(_ id: Int) {
            transcribeOrder.append(id)
            concurrentTranscribes += 1
            maxConcurrentTranscribes = max(maxConcurrentTranscribes, concurrentTranscribes)
        }
        func endTranscribe() { concurrentTranscribes -= 1 }
        func present(_ id: Int, _ outcome: DictationFinalizeQueue.Outcome) {
            presentOrder.append((id, outcome))
        }
    }

    /// One-shot gate so a test can hold a transcription open while it mutates the
    /// queue (e.g. cancels a still-queued successor).
    private actor AsyncGate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
    }

    private func waitForDrain(_ queue: DictationFinalizeQueue, timeoutMs: UInt64 = 5_000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if await queue.depth == 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPresentsInStrictEnqueueOrderDespiteVaryingTranscribeTimes() async {
        let rec = Recorder()
        // Earlier jobs transcribe SLOWER than later ones — a non-serial or
        // un-ordered queue would present them out of order. Serial + ordered
        // must still yield 1,2,3.
        let delays = [1: 60, 2: 20, 3: 5]
        let queue = DictationFinalizeQueue(
            transcribe: { id in
                await rec.beginTranscribe(id)
                try? await Task.sleep(for: .milliseconds(delays[id] ?? 0))
                await rec.endTranscribe()
                return .success
            },
            present: { id, outcome in await rec.present(id, outcome) }
        )
        for id in [1, 2, 3] { await queue.enqueue(sessionID: id) }
        await waitForDrain(queue)

        let presented = await rec.presentOrder.map(\.id)
        XCTAssertEqual(presented, [1, 2, 3])
        let maxConcurrent = await rec.maxConcurrentTranscribes
        XCTAssertEqual(maxConcurrent, 1, "transcriptions must never run concurrently")
    }

    func testNothingIsDropped() async {
        let rec = Recorder()
        let queue = DictationFinalizeQueue(
            transcribe: { _ in .success },
            present: { id, outcome in await rec.present(id, outcome) }
        )
        for id in 1...5 { await queue.enqueue(sessionID: id) }
        await waitForDrain(queue)
        let presented = await rec.presentOrder.map(\.id)
        XCTAssertEqual(presented, [1, 2, 3, 4, 5])
    }

    func testFailureAndNoSpeechArePresentedAndDoNotBlockSuccessors() async {
        let rec = Recorder()
        let queue = DictationFinalizeQueue(
            transcribe: { id in
                switch id {
                case 2: return .failure("boom")
                case 3: return .noSpeech
                default: return .success
                }
            },
            present: { id, outcome in await rec.present(id, outcome) }
        )
        for id in [1, 2, 3, 4] { await queue.enqueue(sessionID: id) }
        await waitForDrain(queue)

        let presented = await rec.presentOrder
        XCTAssertEqual(presented.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(presented[1].outcome, .failure("boom"))
        XCTAssertEqual(presented[2].outcome, .noSpeech)
    }

    func testCancelBeforeTranscribeSkipsJobEntirely() async {
        let rec = Recorder()
        let gate = AsyncGate()
        let queue = DictationFinalizeQueue(
            transcribe: { id in
                if id == 1 { await gate.wait() }  // hold the head open
                await rec.beginTranscribe(id)
                await rec.endTranscribe()
                return .success
            },
            present: { id, outcome in await rec.present(id, outcome) }
        )
        await queue.enqueue(sessionID: 1)
        await queue.enqueue(sessionID: 2)
        await queue.enqueue(sessionID: 3)
        await queue.cancel(sessionID: 2)  // 2 is still queued, not yet started
        await gate.open()
        await waitForDrain(queue)

        let presented = await rec.presentOrder.map(\.id)
        let transcribed = await rec.transcribeOrder
        XCTAssertEqual(presented, [1, 3])
        XCTAssertFalse(transcribed.contains(2), "cancelled-while-queued job must not transcribe")
    }

    func testCancelDuringTranscribeKeepsTranscriptionButSkipsPresent() async {
        let rec = Recorder()
        let gate = AsyncGate()
        let queue = DictationFinalizeQueue(
            transcribe: { id in
                await rec.beginTranscribe(id)
                if id == 1 { await gate.wait() }  // 1 is mid-transcribe
                await rec.endTranscribe()
                return .success
            },
            present: { id, outcome in await rec.present(id, outcome) }
        )
        await queue.enqueue(sessionID: 1)
        await queue.enqueue(sessionID: 2)
        // Let 1 start transcribing, then cancel it mid-flight.
        try? await Task.sleep(for: .milliseconds(20))
        await queue.cancel(sessionID: 1)
        await gate.open()
        await waitForDrain(queue)

        let transcribed = await rec.transcribeOrder
        let presented = await rec.presentOrder.map(\.id)
        XCTAssertTrue(transcribed.contains(1), "in-flight transcription is not aborted")
        XCTAssertEqual(presented, [2], "cancelled job's paste is skipped")
    }
}
