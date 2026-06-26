import Foundation

/// Pure cosine matching of a speaker embedding against enrolled profiles.
///
/// No model or I/O — fully testable in isolation. Embeddings from
/// `SpeakerEmbeddingService` are already L2-normalized, but the cosine is
/// computed robustly so an un-normalized vector still matches sensibly.
public enum SpeakerMatcher {
    /// Maximum cosine distance (`1 - cosine similarity`) for an embedding to be
    /// accepted as the same speaker. Lower = stricter (fewer false matches).
    ///
    /// Mislabeling a speaker with the wrong name is worse than leaving them
    /// anonymous, so this defaults conservatively. Tuned against real meetings
    /// during validation (the Python reference pipeline used ~0.45 on a
    /// different embedding model).
    public static let defaultMaxDistance: Float = 0.5

    public struct Match: Sendable, Equatable {
        public let profileID: UUID
        public let name: String
        public let distance: Float

        public init(profileID: UUID, name: String, distance: Float) {
            self.profileID = profileID
            self.name = name
            self.distance = distance
        }
    }

    /// Cosine distance in `[0, 2]`; `0` is identical direction. Returns
    /// `.greatestFiniteMagnitude` for mismatched/empty/degenerate inputs so they
    /// never spuriously match.
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 0 else { return .greatestFiniteMagnitude }
        let cosine = max(-1, min(1, dot / denom))
        return 1 - cosine
    }

    /// Best matching profile for `embedding`, or `nil` if none is within
    /// `maxDistance`.
    ///
    /// `candidates` should be the speakers expected to be present — all enrolled
    /// profiles, or a per-meeting subset. A smaller, accurate candidate set
    /// materially reduces false matches.
    public static func bestMatch(
        for embedding: [Float],
        among candidates: [SpeakerProfile],
        maxDistance: Float = defaultMaxDistance
    ) -> Match? {
        var best: Match?
        for profile in candidates {
            let distance = cosineDistance(embedding, profile.embedding)
            guard distance <= maxDistance else { continue }
            if best == nil || distance < best!.distance {
                best = Match(profileID: profile.id, name: profile.name, distance: distance)
            }
        }
        return best
    }
}
