import Foundation

/// Layers named-speaker recognition on top of anonymous diarization.
///
/// Given a diarization result and the mono-16k audio that was diarized, this
/// re-embeds each anonymous speaker cluster (via `SpeakerEmbeddingService`) and
/// matches it against enrolled profiles (via `SpeakerMatcher`). It returns, per
/// diarization speaker id, the matched profile or `nil` when there is no
/// confident match.
///
/// Re-embedding each cluster — rather than reusing the offline diarization
/// pipeline's internal vectors — is deliberate: it keeps cluster embeddings in
/// the same vector space as enrollment embeddings, which is what makes cosine
/// matching valid.
public actor SpeakerRecognizer {
    public struct Recognition: Sendable, Equatable {
        /// Diarization-local speaker id (e.g. "S1").
        public let speakerID: String
        /// Matched profile, or `nil` if the cluster stayed anonymous.
        public let match: SpeakerMatcher.Match?

        public init(speakerID: String, match: SpeakerMatcher.Match?) {
            self.speakerID = speakerID
            self.match = match
        }
    }

    private let embedding: SpeakerEmbeddingServiceProtocol
    /// Cap on how much of a speaker's audio to embed. Longest segments are used
    /// first (cleaner, more centered speech); 30 s is ample for a stable
    /// embedding and bounds work on long meetings.
    private let maxEmbedSecondsPerSpeaker: Double
    /// A cluster with less than this much speech is left anonymous — too little
    /// audio to embed reliably.
    private let minEmbedSeconds: Double

    public init(
        embedding: SpeakerEmbeddingServiceProtocol,
        maxEmbedSecondsPerSpeaker: Double = 30,
        minEmbedSeconds: Double = 1.0
    ) {
        self.embedding = embedding
        self.maxEmbedSecondsPerSpeaker = maxEmbedSecondsPerSpeaker
        self.minEmbedSeconds = minEmbedSeconds
    }

    /// - Parameters:
    ///   - diarization: anonymous result from `DiarizationService`.
    ///   - samples16k: the same mono-16k audio that was diarized.
    ///   - profiles: enrolled candidates expected to be present. A smaller,
    ///     accurate candidate set reduces false matches.
    ///   - maxDistance: cosine-distance ceiling for a match.
    /// - Returns: one `Recognition` per diarization speaker, in the same order.
    public func recognize(
        diarization: MacParakeetDiarizationResult,
        samples16k: [Float],
        profiles: [SpeakerProfile],
        maxDistance: Float = SpeakerMatcher.defaultMaxDistance
    ) async throws -> [Recognition] {
        guard !profiles.isEmpty, !diarization.speakers.isEmpty, !samples16k.isEmpty else {
            return diarization.speakers.map { Recognition(speakerID: $0.id, match: nil) }
        }

        let sampleRate = 16_000
        let maxSamples = Int(maxEmbedSecondsPerSpeaker * Double(sampleRate))
        let minSamples = Int(minEmbedSeconds * Double(sampleRate))

        var results: [Recognition] = []
        results.reserveCapacity(diarization.speakers.count)

        for speaker in diarization.speakers {
            let speakerSegments = diarization.segments
                .filter { $0.speakerId == speaker.id }
                .sorted { ($0.endMs - $0.startMs) > ($1.endMs - $1.startMs) }
            let clusterSamples = Self.gatherSamples(
                segments: speakerSegments,
                from: samples16k,
                sampleRate: sampleRate,
                maxSamples: maxSamples
            )
            guard clusterSamples.count >= minSamples else {
                results.append(Recognition(speakerID: speaker.id, match: nil))
                continue
            }
            let vector = try await embedding.embed(samples: clusterSamples)
            let match = SpeakerMatcher.bestMatch(
                for: vector,
                among: profiles,
                maxDistance: maxDistance
            )
            results.append(Recognition(speakerID: speaker.id, match: match))
        }
        return results
    }

    /// Concatenate a speaker's segment audio (longest segments first) up to
    /// `maxSamples`. Segment bounds are clamped to the sample buffer.
    public static func gatherSamples(
        segments: [SpeakerSegment],
        from samples: [Float],
        sampleRate: Int,
        maxSamples: Int
    ) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(min(maxSamples, samples.count))
        for segment in segments {
            if out.count >= maxSamples { break }
            let start = max(0, segment.startMs * sampleRate / 1000)
            let end = min(samples.count, segment.endMs * sampleRate / 1000)
            guard start < end else { continue }
            let take = min(end - start, maxSamples - out.count)
            out.append(contentsOf: samples[start..<(start + take)])
        }
        return out
    }
}
