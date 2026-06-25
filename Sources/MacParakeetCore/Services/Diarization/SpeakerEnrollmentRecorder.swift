import AVFoundation
import Foundation

/// Captures a short microphone clip for speaker enrollment, reusing the shared
/// microphone stream (same capture path as dictation) and downmix/resample
/// helper so the result is mono-16k `Float` — exactly what
/// `SpeakerEmbeddingService.embed` expects.
///
/// No pre-roll, heartbeat, or file writing: just accumulate samples up to a cap
/// and hand them back. Buffers arrive on the real-time audio thread, so they are
/// appended under a lock (never an actor hop on the audio thread).
public actor SpeakerEnrollmentRecorder {
    private let sharedStream: SharedMicrophoneStream
    private let maxSeconds: Double
    private let sampleRate = 16_000
    private let buffer = LockedSampleBuffer()
    private var token: SharedMicrophoneStream.SubscriberToken?
    private var isRecording = false

    public init(sharedStream: SharedMicrophoneStream, maxSeconds: Double = 30) {
        self.sharedStream = sharedStream
        self.maxSeconds = maxSeconds
    }

    /// Seconds captured so far — poll for live progress UI.
    public var capturedSeconds: Double {
        Double(buffer.count) / Double(sampleRate)
    }

    public func start() async throws {
        guard !isRecording else { return }
        buffer.reset()
        let sink = buffer
        let limit = Int(maxSeconds * Double(sampleRate))
        token = try await sharedStream.subscribe(wantsVPIO: false) { pcm, _ in
            if let samples = AudioChunker.extractAndResample(from: pcm) {
                sink.append(samples, limit: limit)
            }
        }
        isRecording = true
    }

    /// Stop capture and return the accumulated mono-16k samples.
    @discardableResult
    public func stop() async -> [Float] {
        if let token {
            await sharedStream.unsubscribe(token)
            self.token = nil
        }
        isRecording = false
        return buffer.snapshot()
    }
}

/// Thread-safe Float accumulator. The audio thread appends; the actor reads.
private final class LockedSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func reset() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }

    func append(_ incoming: [Float], limit: Int) {
        lock.lock(); defer { lock.unlock() }
        guard samples.count < limit else { return }
        let room = limit - samples.count
        if incoming.count <= room {
            samples.append(contentsOf: incoming)
        } else {
            samples.append(contentsOf: incoming.prefix(room))
        }
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }
}
