import Foundation

/// Extracts one diarized speaker's audio from a *saved* transcription so it can
/// be embedded into a `SpeakerProfile` — i.e. "this speaker was Sara, remember
/// her voice." Shared by the in-app transcript flow and the CLI.
///
/// Uses the retained mixed audio (`Transcription.filePath`); diarization segment
/// times are already absolute into that file (the system-track offset is applied
/// at finalization), so segments slice directly. The separate system WAV the
/// diarizer ran on is a temp file that no longer exists post-finalization.
///
/// Audio is governed by retention (meetings default to 30 days), so the file may
/// be gone — callers must handle `.audioUnavailable` as an expected outcome, not
/// an error, and enroll while the recording is still on disk.
public enum SpeakerEnrollmentFromRecording {
    public enum ExtractionError: Error, Equatable {
        /// The recording's audio file is missing (never saved, or purged by retention).
        case audioUnavailable
        /// The transcription has no diarization data (speaker detection was off).
        case segmentsMissing
        /// No segments for the requested speaker id.
        case speakerNotFound
        /// Gathered less than `minSeconds` of speech — too little for a reliable embedding.
        case tooShort(seconds: Double)
    }

    /// Produce 16 kHz mono samples for `speakerId`, taking the speaker's longest
    /// segments first up to `maxSeconds`.
    public static func extractSamples(
        transcription: Transcription,
        speakerId: String,
        maxSeconds: Double = 30,
        minSeconds: Double = 1,
        sampleRate: Int = 16_000
    ) throws -> (samples: [Float], seconds: Double) {
        guard let path = transcription.filePath,
              FileManager.default.fileExists(atPath: path) else {
            throw ExtractionError.audioUnavailable
        }
        guard let segments = transcription.diarizationSegments, !segments.isEmpty else {
            throw ExtractionError.segmentsMissing
        }
        let mine = segments.filter { $0.speakerId == speakerId }
        guard !mine.isEmpty else { throw ExtractionError.speakerNotFound }

        let allSamples = try MeetingVADChunkingSimulator.loadSamples16k(url: URL(fileURLWithPath: path))
        let speakerSegments = mine
            .sorted { ($0.endMs - $0.startMs) > ($1.endMs - $1.startMs) }
            .map { SpeakerSegment(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs) }
        let gathered = SpeakerRecognizer.gatherSamples(
            segments: speakerSegments,
            from: allSamples,
            sampleRate: sampleRate,
            maxSamples: Int(maxSeconds * Double(sampleRate))
        )
        let seconds = Double(gathered.count) / Double(sampleRate)
        guard seconds >= minSeconds else { throw ExtractionError.tooShort(seconds: seconds) }
        return (gathered, seconds)
    }
}
