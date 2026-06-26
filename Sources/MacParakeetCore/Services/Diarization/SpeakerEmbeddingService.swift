import FluidAudio
import Foundation

/// Produces L2-normalized 256-d speaker embeddings from 16 kHz mono audio using
/// FluidAudio's streaming diarizer embedding model (pyannote segmentation +
/// wespeaker_v2).
///
/// Used in two places, and deliberately the *same* code path in both so the
/// vectors are cosine-comparable:
/// - Enrollment: embed a recorded voice sample to build a `SpeakerProfile`.
/// - Recognition: re-embed each anonymous diarization cluster's audio to match
///   it against enrolled profiles (see `SpeakerMatcher`).
///
/// This is intentionally separate from `DiarizationService`, which uses the
/// higher-accuracy *offline* pipeline for "who spoke when". The offline
/// pipeline's internal embeddings use different preprocessing and are not
/// directly comparable to enrollment embeddings, so naming is layered on top
/// via this consistent embedder rather than reusing the offline vectors.
public protocol SpeakerEmbeddingServiceProtocol: Sendable {
    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws
    /// Extract a single L2-normalized 256-d embedding from 16 kHz mono samples
    /// of one speaker. Caller is responsible for passing reasonably clean,
    /// single-speaker audio (an enrollment clip, or one diarized cluster).
    func embed(samples: [Float]) async throws -> [Float]
    func isReady() async -> Bool
}

extension SpeakerEmbeddingServiceProtocol {
    public func prepareModels() async throws {
        try await prepareModels(onProgress: nil)
    }
}

public actor SpeakerEmbeddingService: SpeakerEmbeddingServiceProtocol {
    private let manager: DiarizerManager
    private let modelsDirectory: URL?
    private var modelsReady = false

    public init(modelsDirectory: URL? = nil) {
        self.manager = DiarizerManager()
        self.modelsDirectory = modelsDirectory
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await ensureModelsPrepared(onProgress: onProgress)
    }

    public func embed(samples: [Float]) async throws -> [Float] {
        try await ensureModelsPrepared(onProgress: nil)
        return try manager.extractSpeakerEmbedding(from: samples)
    }

    public func isReady() async -> Bool { modelsReady }

    private func ensureModelsPrepared(onProgress: (@Sendable (String) -> Void)?) async throws {
        guard !modelsReady else { return }
        onProgress?("Loading speaker recognition model…")
        let models = try await DiarizerModels.download(to: modelsDirectory)
        manager.initialize(models: models)
        modelsReady = true
        onProgress?("Speaker recognition model ready")
    }
}
