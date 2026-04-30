import AVFoundation
import Foundation
import os

/// Abstract surface that `SharedMicrophoneStream` uses to drive real
/// `AVAudioEngine` operations. Splitting it out lets unit tests exercise the
/// stream's state machine and fan-out under a deterministic mock, while the
/// production adapter handles the Core Audio side.
///
/// Implementations must serialize concurrent calls. `SharedMicrophoneStream`
/// also serializes via its own engine queue, so platform implementations may
/// rely on that — but they must remain reentrancy-safe (e.g. handle a stop
/// during a partially-failed start).
public protocol MicrophoneEnginePlatform: AnyObject, Sendable {
    /// True between a successful `configureAndStart` and the next
    /// `stopEngine`. Implementations may also set this to `false` if the
    /// engine fails post-start.
    var isEngineRunning: Bool { get }

    /// Live input format reported by the running engine, or `nil` if the
    /// engine is not running or its format is invalid.
    var inputFormat: AVAudioFormat? { get }

    /// Idempotent start. Stops any existing engine and rebuilds it with the
    /// requested VPIO mode. Installs `tapHandler` as the buffer callback;
    /// the handler runs on the audio render thread.
    ///
    /// - Important: The buffer passed to `tapHandler` is valid only for the
    ///   synchronous duration of the call. Implementations must not retain
    ///   the buffer past return.
    func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws

    /// Stop the engine, remove the tap, and tear down VPIO. Recreates the
    /// underlying `AVAudioEngine` so coreaudiod releases the VPAU aggregate
    /// (`CADefaultDeviceAggregate-<pid>-N`). Mirrors the ephemeral-engine
    /// pattern proven in `MicrophoneCapture` (PR #186).
    func stopEngine()
}

/// Production adapter that drives a real `AVAudioEngine`. Mirrors the
/// engine-lifecycle invariants from `MicrophoneCapture` (PR #186):
///
/// - VPIO ducking is suppressed so other apps' audio isn't ~50% attenuated.
/// - The engine is destroyed and recreated on stop so coreaudiod releases
///   the VPAU aggregate device. A long-lived engine keeps the VPAU alive
///   indefinitely, which inherits the duplex layout into other engines.
/// - When configured with a `deviceAttemptsBuilder`, each `configureAndStart`
///   walks the resolved attempt list (selected → systemDefault → builtIn) and
///   recreates the engine on every failed attempt before trying the next —
///   the same fallback shape `MicrophoneCapture` uses today.
public final class AVAudioEngineMicrophonePlatform: MicrophoneEnginePlatform, @unchecked Sendable {
    public typealias DeviceAttemptsBuilder = @Sendable () -> [MeetingInputDeviceAttempt]

    private let logger = Logger(
        subsystem: "com.macparakeet.core",
        category: "AVAudioEngineMicrophonePlatform"
    )
    private let queue = DispatchQueue(label: "com.macparakeet.shared-mic-platform")
    private let deviceAttemptsBuilder: DeviceAttemptsBuilder?
    private var audioEngine = AVAudioEngine()
    private var running: Bool = false
    private var lastSucceededAttemptLocked: MeetingInputDeviceAttempt?

    public init(deviceAttemptsBuilder: DeviceAttemptsBuilder? = nil) {
        self.deviceAttemptsBuilder = deviceAttemptsBuilder
    }

    public var isEngineRunning: Bool {
        // Must not be called from the platform's own queue — `queue.sync`
        // would deadlock. Caller is expected to be on a different queue
        // (typically `SharedMicrophoneStream.engineQueue` or a UI thread).
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { running }
    }

    public var inputFormat: AVAudioFormat? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        let snapshot: AVAudioEngine? = queue.sync {
            running ? audioEngine : nil
        }
        guard let snapshot else { return nil }
        let format = snapshot.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 ? format : nil
    }

    /// The device attempt that produced the most recent successful start, or
    /// `nil` if no `deviceAttemptsBuilder` was configured (the engine used
    /// whatever device the system chose) or the platform is not running.
    public var lastSucceededAttempt: MeetingInputDeviceAttempt? {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { running ? lastSucceededAttemptLocked : nil }
    }

    public func configureAndStart(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        try queue.sync {
            // VPIO toggle requires a stop → setVoiceProcessingEnabled → start
            // sequence; the engine cannot be reconfigured while running.
            if running {
                tearDownLocked()
            }

            let attempts = deviceAttemptsBuilder?() ?? []
            if attempts.isEmpty {
                // No device chain — use whatever the engine's input node picks.
                try startEngineLocked(
                    vpioEnabled: vpioEnabled,
                    bufferSize: bufferSize,
                    tapHandler: tapHandler
                )
                lastSucceededAttemptLocked = nil
                return
            }

            var lastError: Error?
            for attempt in attempts {
                guard AudioDeviceManager.setInputDevice(attempt.deviceID, on: audioEngine) else {
                    logger.warning(
                        "shared_mic_engine_input_device_set_failed source=\(attempt.source.logValue, privacy: .public) id=\(attempt.deviceID, privacy: .public)"
                    )
                    if lastError == nil {
                        lastError = AVAudioEngineMicrophonePlatformError.deviceSetFailed(attempt)
                    }
                    resetEngineLocked()
                    continue
                }

                do {
                    try startEngineLocked(
                        vpioEnabled: vpioEnabled,
                        bufferSize: bufferSize,
                        tapHandler: tapHandler
                    )
                    lastSucceededAttemptLocked = attempt
                    let name = AudioDeviceManager.deviceName(attempt.deviceID) ?? "unknown"
                    logger.info(
                        "shared_mic_engine_input_device_started source=\(attempt.source.logValue, privacy: .public) id=\(attempt.deviceID, privacy: .public) name=\(name, privacy: .public) vpio=\(vpioEnabled, privacy: .public)"
                    )
                    return
                } catch {
                    lastError = error
                    logger.warning(
                        "shared_mic_engine_input_device_start_failed source=\(attempt.source.logValue, privacy: .public) id=\(attempt.deviceID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    // startEngineLocked already replaces the engine on
                    // failure, so nothing more to reset here.
                }
            }

            throw lastError ?? AVAudioEngineMicrophonePlatformError.noDeviceAvailable
        }
    }

    public func stopEngine() {
        queue.sync {
            guard running else { return }
            tearDownLocked()
            logger.info("shared_mic_engine_stopped")
        }
    }

    // MARK: - Internals (queue-held)

    private func startEngineLocked(
        vpioEnabled: Bool,
        bufferSize: AVAudioFrameCount,
        tapHandler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        let inputNode = audioEngine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(vpioEnabled)
        } catch {
            // VPIO toggle failed before tap install / engine start. Replace
            // the engine so the next attempt isn't on a half-configured one.
            audioEngine = AVAudioEngine()
            throw error
        }
        if vpioEnabled, #available(macOS 14.0, *) {
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: nil
        ) { buffer, time in
            tapHandler(buffer, time)
        }

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? inputNode.setVoiceProcessingEnabled(false)
            audioEngine = AVAudioEngine()
            throw error
        }
        running = true
    }

    private func tearDownLocked() {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        try? inputNode.setVoiceProcessingEnabled(false)
        audioEngine.stop()
        // Replace the engine. Releasing the old instance tears down the
        // VPAU aggregate device coreaudiod created for it, so a sibling
        // AVAudioEngine in the same process doesn't inherit duplex layout.
        audioEngine = AVAudioEngine()
        running = false
        lastSucceededAttemptLocked = nil
    }

    /// Reset between failed device attempts (no tap installed yet, just
    /// hand back a fresh engine for the next try).
    private func resetEngineLocked() {
        audioEngine.stop()
        audioEngine = AVAudioEngine()
    }
}

public enum AVAudioEngineMicrophonePlatformError: Error, Equatable {
    case deviceSetFailed(MeetingInputDeviceAttempt)
    case noDeviceAvailable
}
