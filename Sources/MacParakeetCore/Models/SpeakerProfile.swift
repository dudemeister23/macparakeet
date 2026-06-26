import Foundation
import GRDB

/// A persisted voice profile for a known speaker.
///
/// `embedding` is a 256-dimensional, L2-normalized speaker vector produced by
/// FluidAudio's diarizer embedding model (see `DiarizationService.enroll`).
/// Profiles let meeting diarization attribute anonymous speaker clusters to real
/// names by cosine-matching each cluster's embedding against enrolled profiles
/// (see `SpeakerRecognizer`). The user enrolls a profile once by recording a
/// short voice sample; the same profile is then reused across all meetings.
///
/// Stored locally like all other user data — embeddings never leave the device.
public struct SpeakerProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    /// Display name shown in transcripts (e.g. "Sara"). Used as the speaker
    /// label when a diarized cluster matches this profile.
    public var name: String
    /// 256-d L2-normalized voice embedding. Persisted as JSON in a text column
    /// (GRDB encodes non-scalar Codable properties as JSON automatically, the
    /// same way `Transcription.speakers` is stored).
    public var embedding: [Float]
    /// Total seconds of enrollment speech captured, surfaced in the management
    /// UI as a rough quality hint (longer enrollment → more reliable matching).
    public var enrolledSeconds: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        enrolledSeconds: Double = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.enrolledSeconds = enrolledSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SpeakerProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "speaker_profiles"
}
