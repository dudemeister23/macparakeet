import AVFoundation
import XCTest
@testable import MacParakeetCore

final class AudioRecorderFormatChangeTests: XCTestCase {
    func testTapConverterNeedsRebuildWhenNoCachedFormat() throws {
        let incoming = try makeFormat()
        XCTAssertTrue(tapConverterNeedsRebuild(cachedSourceFormat: nil, incomingBufferFormat: incoming))
    }

    func testTapConverterDoesNotNeedRebuildForEquivalentFormat() throws {
        let cached = try makeFormat()
        let incoming = try makeFormat()
        XCTAssertFalse(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    func testTapConverterNeedsRebuildWhenInterleavingChanges() throws {
        let nonInterleaved = try makeFormat(interleaved: false)
        let interleaved = try makeFormat(interleaved: true)
        XCTAssertTrue(
            tapConverterNeedsRebuild(
                cachedSourceFormat: nonInterleaved,
                incomingBufferFormat: interleaved
            )
        )
    }

    func testTapConverterNeedsRebuildWhenSampleRateChanges() throws {
        let cached = try makeFormat(sampleRate: 48_000)
        let incoming = try makeFormat(sampleRate: 44_100)
        XCTAssertTrue(
            tapConverterNeedsRebuild(cachedSourceFormat: cached, incomingBufferFormat: incoming)
        )
    }

    func testSharedModeStopDuringStartAbortsPendingSubscription() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }

        let startTask = Task {
            try await recorder.start()
        }

        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should throw while start is still pending")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "Not recording")
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }

        release.signal()

        do {
            try await startTask.value
            XCTFail("start() should abort after stop invalidates the pending generation")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "interrupted during subscribe")
        } catch {
            XCTFail("Unexpected start error: \(error)")
        }

        try await Task.sleep(for: .milliseconds(50))
        let isRecording = await recorder.isRecording
        XCTAssertFalse(isRecording)
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0)
        XCTAssertFalse(stream.diagnostics.engineRunning)
    }

    /// Reproduces the double-tap dictation race. Sequence is:
    ///   1. start #1 (provisional hold-to-talk) suspends in subscribe
    ///   2. stop runs (fn-up discard) — bumps generation, resets `starting`
    ///   3. start #2 (persistent double-tap) enters and suspends in subscribe
    ///   4. start #1's subscribe resumes — lostRace throws, defer clears `starting`
    ///   5. start #2's subscribe resumes — must succeed
    ///
    /// Today's bug: start #1's `defer { starting = false }` clobbers start #2's
    /// `starting = true` between #1's throw and #2's lostRace check, so #2's
    /// `!self.starting` clause trips lostRace and the user-wanted persistent
    /// recording also aborts. After the fix, only the generation check governs
    /// lostRace, and start #2 succeeds.
    func testSharedModeStartAfterStopDuringFirstStartSucceeds() async throws {
        let platform = AudioRecorderBlockingPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let recorder = AudioRecorder(
            sharedStream: stream,
            permissionProvider: { true }
        )

        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        platform.configureAndStartHook = {
            arrived.signal()
            release.wait()
        }

        let task1 = Task { try await recorder.start() }
        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success)

        do {
            _ = try await recorder.stop()
            XCTFail("stop() should throw while start #1 is still pending")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "Not recording")
        } catch {
            XCTFail("Unexpected stop error: \(error)")
        }

        // Disarm the hook so the engineQueue can drain start #2's subscribe
        // (no-op for an already-running engine) without re-blocking.
        platform.configureAndStartHook = nil

        // Launch start #2 while start #1 is still suspended in subscribe.
        let task2 = Task { try await recorder.start() }

        // Give task2 time to enter the actor and reach its own subscribe await.
        // The actor is suspended on subscribe(#1), so task2 reentrant entry is
        // immediate; the sleep just covers Task scheduling latency.
        try await Task.sleep(for: .milliseconds(50))

        // Release start #1's blocked engine startup. Subscribe #1 completes,
        // its continuation resumes on the actor, lostRace throws, defer fires.
        // Then subscribe #2 completes (engine already running) and resumes.
        release.signal()

        do {
            try await task1.value
            XCTFail("start #1 should abort — its generation was bumped by stop")
        } catch AudioProcessorError.recordingFailed(let reason) {
            XCTAssertEqual(reason, "interrupted during subscribe")
        } catch {
            XCTFail("Unexpected start #1 error: \(error)")
        }

        do {
            try await task2.value
        } catch {
            XCTFail("start #2 should succeed after start #1 aborted; got: \(error)")
        }

        let isRecording = await recorder.isRecording
        XCTAssertTrue(isRecording, "start #2 must leave the recorder in recording state")

        // Drain the fire-and-forget unsubscribe(token #1) before asserting
        // subscriber count, then clean up. The cleanup stop() throws
        // `insufficientSamples` because the mock platform never delivers
        // buffers — that's expected here and unrelated to the race we're
        // verifying.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(stream.diagnostics.subscriberCount, 1)
        XCTAssertTrue(stream.diagnostics.engineRunning)

        _ = try? await recorder.stop()
    }

    private func makeFormat(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 2,
        interleaved: Bool = false
    ) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
        )
    }
}

private final class AudioRecorderBlockingPlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    private let lock = NSLock()
    private let hookLock = NSLock()
    private var _isRunning = false
    private var _tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var _configureAndStartHook: (@Sendable () -> Void)?

    var configureAndStartHook: (@Sendable () -> Void)? {
        get { hookLock.withLock { _configureAndStartHook } }
        set { hookLock.withLock { _configureAndStartHook = newValue } }
    }

    var isEngineRunning: Bool {
        lock.withLock { _isRunning }
    }

    var inputFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    }

    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        configureAndStartHook?()
        lock.withLock {
            _isRunning = true
            _tapHandler = tapHandler
        }
    }

    func stopEngine() {
        lock.withLock {
            _isRunning = false
            _tapHandler = nil
        }
    }
}
