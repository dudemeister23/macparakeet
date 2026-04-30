import AVFoundation
import CoreAudio
import XCTest
@testable import MacParakeetCore

final class MicrophoneCaptureTests: XCTestCase {
    func testInitCreatesCaptureInstance() {
        let capture = MicrophoneCapture()
        XCTAssertNotNil(capture)
    }

    // MARK: - Shared-stream path (AppFeatures.useSharedMicEngine = true)

    func testSharedModeSubscribesWithVPIOForVPIOPreferred() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        let report = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in },
            onStall: nil
        )
        defer { capture.stop() }

        XCTAssertEqual(report.requestedMode, .vpioPreferred)
        XCTAssertEqual(report.effectiveMode, .vpio)
        XCTAssertEqual(platform.configureAndStartCalls.count, 1)
        XCTAssertEqual(platform.configureAndStartCalls.first?.vpioEnabled, true)
        XCTAssertTrue(stream.diagnostics.engineRunning)
    }

    func testSharedModeSubscribesRawForRawProcessing() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        let report = try await capture.start(
            processingMode: .raw,
            handler: { _, _ in },
            onStall: nil
        )
        defer { capture.stop() }

        XCTAssertEqual(report.effectiveMode, .raw)
        XCTAssertEqual(platform.configureAndStartCalls.first?.vpioEnabled, false)
    }

    func testSharedModeForwardsBuffersToHandler() async throws {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let counter = MicrophoneCaptureTestCounter()

        _ = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in counter.increment() },
            onStall: nil
        )
        defer { capture.stop() }

        let buffer = makeSharedTestBuffer()
        let time = AVAudioTime(hostTime: 0)
        platform.deliverBuffer(buffer, time: time)
        platform.deliverBuffer(buffer, time: time)

        XCTAssertEqual(counter.value, 2)
    }

    func testSharedModeVPIOPreferredFallsBackToRawWhenSubscribeThrows() async throws {
        let platform = SharedMicTestPlatform()
        platform.configureAndStartError = MicrophoneCaptureMockError.simulatedFailure
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        // Failure on the first attempt (VPIO). Clear the error so the raw
        // retry succeeds.
        platform.configureAndStartError = nil
        platform.failNextStartCount = 1

        let report = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in },
            onStall: nil
        )
        defer { capture.stop() }

        XCTAssertEqual(report.effectiveMode, .raw, "vpioPreferred falls back to raw when VPIO subscribe fails")
        XCTAssertGreaterThanOrEqual(platform.configureAndStartCalls.count, 2, "Both vpio and raw subscribe attempts occur")
        XCTAssertEqual(platform.configureAndStartCalls.last?.vpioEnabled, false, "Final attempt must be the raw retry")
    }

    func testSharedModeVPIORequiredThrowsOnSubscribeFailure() async {
        let platform = SharedMicTestPlatform()
        platform.configureAndStartError = MicrophoneCaptureMockError.simulatedFailure
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )

        do {
            _ = try await capture.start(
                processingMode: .vpioRequired,
                handler: { _, _ in },
                onStall: nil
            )
            XCTFail("vpioRequired must throw when VPIO can't engage")
        } catch MeetingAudioError.microphoneProcessingUnavailable(let mode, _) {
            XCTAssertEqual(mode, .vpioRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(stream.diagnostics.subscriberCount, 0)
    }

    func testSharedModeThrowsPermissionDeniedWhenProviderFalse() async {
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { false }
        )

        do {
            _ = try await capture.start(
                processingMode: .raw,
                handler: { _, _ in },
                onStall: nil
            )
            XCTFail("Expected microphonePermissionDenied")
        } catch MeetingAudioError.microphonePermissionDenied {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(platform.configureAndStartCalls.count, 0, "Permission gate must short-circuit before any platform call")
    }

    func testSharedModeEngineDeathSurfacesAsStall() async throws {
        // When a deferred-VPIO promotion fails, MicrophoneCapture must
        // forward the engine-death notification to its `onStall` observer.
        let platform = SharedMicTestPlatform()
        let stream = SharedMicrophoneStream(platform: platform, bufferSize: 1024)
        let capture = MicrophoneCapture(
            sharedStream: stream,
            permissionProvider: { true }
        )
        let stallBox = MicrophoneCaptureTestStallBox()

        // Pre-seed a non-VPIO blocker so the capture's VPIO subscribe gets deferred.
        let blockerToken = try await stream.subscribe(wantsVPIO: false) { _, _ in }
        defer { Task { await stream.unsubscribe(blockerToken) } }

        _ = try await capture.start(
            processingMode: .vpioPreferred,
            handler: { _, _ in },
            onStall: { error in stallBox.record(error) }
        )
        defer { capture.stop() }
        XCTAssertTrue(stream.diagnostics.vpioDeferred)

        // Make the deferred promotion fail when the blocker leaves.
        platform.configureAndStartError = MicrophoneCaptureMockError.simulatedFailure
        await stream.unsubscribe(blockerToken)

        XCTAssertNotNil(stallBox.recordedError, "Engine death must reach onStall")
    }

    func testInputDeviceAttemptsPreferSelectedThenDefaultThenBuiltIn() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "usb-mic",
            selectedInputDeviceID: { uid in uid == "usb-mic" ? AudioDeviceID(10) : nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .selected(uid: "usb-mic"), deviceID: 10),
                MeetingInputDeviceAttempt(source: .systemDefault, deviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    func testInputDeviceAttemptsSkipMissingSelectedDevice() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: "missing-mic",
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(20) },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .systemDefault, deviceID: 20),
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    func testInputDeviceAttemptsDeduplicateDefaultAndBuiltIn() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { AudioDeviceID(30) },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .systemDefault, deviceID: 30),
            ]
        )
    }

    func testInputDeviceAttemptsCanUseBuiltInWhenDefaultMissing() {
        let attempts = meetingInputDeviceAttempts(
            selectedUID: nil,
            selectedInputDeviceID: { _ in nil },
            defaultInputDevice: { nil },
            builtInMicrophone: { AudioDeviceID(30) }
        )

        XCTAssertEqual(
            attempts,
            [
                MeetingInputDeviceAttempt(source: .builtIn, deviceID: 30),
            ]
        )
    }

    private func makeSharedTestBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        return buffer
    }
}

// MARK: - Test doubles for shared-stream path

private enum MicrophoneCaptureMockError: Error, Equatable {
    case simulatedFailure
}

private final class MicrophoneCaptureTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private final class MicrophoneCaptureTestStallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: MeetingAudioError?
    func record(_ error: MeetingAudioError) {
        lock.withLock { _error = error }
    }
    var recordedError: MeetingAudioError? {
        lock.withLock { _error }
    }
}

/// Lightweight platform double for `MicrophoneCapture` shared-mode tests.
/// Mirrors `SharedMicrophoneStreamTests`'s `MockMicrophonePlatform` shape but
/// duplicated here to keep the two test files independent.
private final class SharedMicTestPlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    struct ConfigureCall: Equatable {
        let vpioEnabled: Bool
        let bufferSize: AVAudioFrameCount
    }

    private let lock = NSLock()
    private var _isRunning = false
    private var _configureCalls: [ConfigureCall] = []
    private var _stopCount = 0
    private var _tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var configureAndStartError: Error?
    /// Counts down on each successful start. While >0, treat the call as a
    /// failure even if `configureAndStartError` is nil. Lets a test simulate
    /// "first attempt fails, second succeeds."
    var failNextStartCount: Int = 0

    var isEngineRunning: Bool {
        lock.withLock { _isRunning }
    }

    var inputFormat: AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    }

    var configureAndStartCalls: [ConfigureCall] {
        lock.withLock { _configureCalls }
    }

    var stopEngineCallCount: Int {
        lock.withLock { _stopCount }
    }

    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        let shouldThrow: Error? = lock.withLock {
            _configureCalls.append(ConfigureCall(vpioEnabled: vpioEnabled, bufferSize: bufferSize))
            if let err = configureAndStartError { return err }
            if failNextStartCount > 0 {
                failNextStartCount -= 1
                return MicrophoneCaptureMockError.simulatedFailure
            }
            return nil
        }
        if let shouldThrow {
            throw shouldThrow
        }
        lock.withLock {
            _isRunning = true
            _tapHandler = tapHandler
        }
    }

    func stopEngine() {
        lock.withLock {
            _isRunning = false
            _tapHandler = nil
            _stopCount += 1
        }
    }

    func deliverBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let handler = lock.withLock { _tapHandler }
        handler?(buffer, time)
    }
}
