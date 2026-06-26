import AVFoundation
import Foundation

/// Writes mono 16 kHz `Float` samples to a WAV file — the format the STT and
/// diarizer models consume. Used to hand a single speaker-turn's audio to the
/// Cohere engine (which takes a file URL), and shared with the CLI.
public enum AudioSampleWAVWriter {
    public static func writeMono16k(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunkFrames = 1 << 16
        var offset = 0
        while offset < samples.count {
            let count = min(chunkFrames, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let destination = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { source in
                    destination.update(from: source.baseAddress!.advanced(by: offset), count: count)
                }
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}
