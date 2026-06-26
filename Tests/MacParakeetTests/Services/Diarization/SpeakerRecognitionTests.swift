import Foundation
import XCTest

@testable import MacParakeetCore

/// Returns preset embeddings in call order, so a test can script exactly what
/// each diarization cluster "embeds" to without loading a CoreML model.
private actor MockEmbedder: SpeakerEmbeddingServiceProtocol {
    private let queued: [[Float]]
    private var index = 0
    private(set) var embedCallCount = 0

    init(queued: [[Float]]) { self.queued = queued }

    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {}
    func isReady() async -> Bool { true }

    func embed(samples: [Float]) async throws -> [Float] {
        defer { index += 1; embedCallCount += 1 }
        return index < queued.count ? queued[index] : []
    }
}

final class SpeakerRecognitionTests: XCTestCase {
    // MARK: - SpeakerMatcher

    func testCosineDistanceIdenticalIsZero() {
        let v: [Float] = [1, 0, 0, 0]
        XCTAssertEqual(SpeakerMatcher.cosineDistance(v, v), 0, accuracy: 1e-5)
    }

    func testCosineDistanceOrthogonalIsOne() {
        XCTAssertEqual(SpeakerMatcher.cosineDistance([1, 0], [0, 1]), 1, accuracy: 1e-5)
    }

    func testCosineDistanceMismatchedLengthIsInfinite() {
        XCTAssertEqual(SpeakerMatcher.cosineDistance([1, 0, 0], [1, 0]), .greatestFiniteMagnitude)
        XCTAssertEqual(SpeakerMatcher.cosineDistance([], []), .greatestFiniteMagnitude)
    }

    func testBestMatchPicksClosestWithinThreshold() {
        let sara = SpeakerProfile(name: "Sara", embedding: [1, 0, 0, 0])
        let mike = SpeakerProfile(name: "Mike", embedding: [0, 1, 0, 0])
        let match = SpeakerMatcher.bestMatch(for: [0.95, 0.05, 0, 0], among: [sara, mike], maxDistance: 0.5)
        XCTAssertEqual(match?.profileID, sara.id)
        XCTAssertEqual(match?.name, "Sara")
    }

    func testBestMatchReturnsNilWhenNoneWithinThreshold() {
        let sara = SpeakerProfile(name: "Sara", embedding: [1, 0, 0, 0])
        let mike = SpeakerProfile(name: "Mike", embedding: [0, 1, 0, 0])
        // Orthogonal to both -> distance 1 > 0.5.
        XCTAssertNil(SpeakerMatcher.bestMatch(for: [0, 0, 1, 0], among: [sara, mike], maxDistance: 0.5))
    }

    func testBestMatchEmptyCandidatesIsNil() {
        XCTAssertNil(SpeakerMatcher.bestMatch(for: [1, 0], among: [], maxDistance: 0.5))
    }

    // MARK: - SpeakerRecognizer

    private func diarization(speakerIDs: [String], segmentMs: [(String, Int, Int)]) -> MacParakeetDiarizationResult {
        let speakers = speakerIDs.map { SpeakerInfo(id: $0, label: "Speaker \($0)") }
        let segments = segmentMs.map { SpeakerSegment(speakerId: $0.0, startMs: $0.1, endMs: $0.2) }
        return MacParakeetDiarizationResult(segments: segments, speakerCount: speakers.count, speakers: speakers)
    }

    func testRecognizeMatchesKnownAndLeavesUnknownAnonymous() async throws {
        let sara = SpeakerProfile(name: "Sara", embedding: [1, 0, 0, 0])
        let mike = SpeakerProfile(name: "Mike", embedding: [0, 1, 0, 0])
        // S1 embeds to ~Sara; S2 embeds orthogonal to everyone -> anonymous.
        let embedder = MockEmbedder(queued: [[1, 0, 0, 0], [0, 0, 1, 0]])
        let recognizer = SpeakerRecognizer(embedding: embedder)

        let diar = diarization(
            speakerIDs: ["S1", "S2"],
            segmentMs: [("S1", 0, 2000), ("S2", 2000, 4000)]
        )
        let samples = [Float](repeating: 0.1, count: 16_000 * 4)  // 4s of mono-16k

        let results = try await recognizer.recognize(
            diarization: diar,
            samples16k: samples,
            profiles: [sara, mike],
            maxDistance: 0.5
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].speakerID, "S1")
        XCTAssertEqual(results[0].match?.name, "Sara")
        XCTAssertEqual(results[1].speakerID, "S2")
        XCTAssertNil(results[1].match)
        let calls = await embedder.embedCallCount
        XCTAssertEqual(calls, 2)
    }

    func testRecognizeWithNoProfilesIsAllAnonymousAndSkipsEmbedding() async throws {
        let embedder = MockEmbedder(queued: [[1, 0, 0, 0]])
        let recognizer = SpeakerRecognizer(embedding: embedder)
        let diar = diarization(speakerIDs: ["S1"], segmentMs: [("S1", 0, 3000)])

        let results = try await recognizer.recognize(
            diarization: diar,
            samples16k: [Float](repeating: 0.1, count: 16_000 * 3),
            profiles: [],
            maxDistance: 0.5
        )

        XCTAssertEqual(results.map(\.speakerID), ["S1"])
        XCTAssertNil(results[0].match)
        let calls = await embedder.embedCallCount
        XCTAssertEqual(calls, 0, "No profiles -> no embedding work")
    }

    func testRecognizeLeavesTooShortClusterAnonymous() async throws {
        let sara = SpeakerProfile(name: "Sara", embedding: [1, 0, 0, 0])
        let embedder = MockEmbedder(queued: [[1, 0, 0, 0]])
        let recognizer = SpeakerRecognizer(embedding: embedder, minEmbedSeconds: 1.0)
        // 400 ms cluster -> below the 1 s floor.
        let diar = diarization(speakerIDs: ["S1"], segmentMs: [("S1", 0, 400)])

        let results = try await recognizer.recognize(
            diarization: diar,
            samples16k: [Float](repeating: 0.1, count: 16_000),
            profiles: [sara],
            maxDistance: 0.5
        )

        XCTAssertNil(results[0].match)
        let calls = await embedder.embedCallCount
        XCTAssertEqual(calls, 0, "Too little audio -> skip embedding")
    }

    func testGatherSamplesPrefersLongestSegmentsAndCaps() {
        let sampleRate = 16_000
        let samples = (0..<(sampleRate * 5)).map { Float($0) }  // 5 s, ramp
        // Two segments: short (0-1s) and long (3-5s, 2s). maxSamples = 2s.
        let segments = [
            SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1000),
            SpeakerSegment(speakerId: "S1", startMs: 3000, endMs: 5000),
        ].sorted { ($0.endMs - $0.startMs) > ($1.endMs - $1.startMs) }

        let gathered = SpeakerRecognizer.gatherSamples(
            segments: segments,
            from: samples,
            sampleRate: sampleRate,
            maxSamples: sampleRate * 2
        )
        XCTAssertEqual(gathered.count, sampleRate * 2)
        // Longest-first: should start at the 3 s segment (sample value 48000).
        XCTAssertEqual(gathered.first, Float(sampleRate * 3))
    }
}
