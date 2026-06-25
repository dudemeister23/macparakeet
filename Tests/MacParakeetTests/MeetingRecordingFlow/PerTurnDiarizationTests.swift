import XCTest

@testable import MacParakeetCore

/// Tests the pure assembly logic behind per-turn Cohere diarization: turn
/// coalescing/offsetting (`TranscriptionService.buildTurns`) and the transcript
/// assembly (`MeetingTranscriptFinalizer.assemblePerTurn`).
final class PerTurnDiarizationTests: XCTestCase {
    // MARK: - buildTurns

    func testMergesAdjacentSameSpeakerWithinGap() {
        let turns = TranscriptionService.buildTurns(
            segments: [
                ("system:S1", 0, 1000),
                ("system:S1", 1500, 2500),   // gap 500ms ≤ 1000 → merge
                ("system:S2", 2600, 3000),   // different speaker → new turn
            ],
            offsetMs: 0,
            mergeGapMs: 1000
        )
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speakerId, "system:S1")
        XCTAssertEqual(turns[0].localStartMs, 0)
        XCTAssertEqual(turns[0].localEndMs, 2500)
        XCTAssertEqual(turns[1].speakerId, "system:S2")
    }

    func testDoesNotMergeAcrossLargeGap() {
        let turns = TranscriptionService.buildTurns(
            segments: [
                ("system:S1", 0, 1000),
                ("system:S1", 3000, 4000),   // gap 2000ms > 1000 → separate
            ],
            offsetMs: 0,
            mergeGapMs: 1000
        )
        XCTAssertEqual(turns.count, 2)
    }

    func testAppliesOffsetToAbsoluteTimes() {
        let turns = TranscriptionService.buildTurns(
            segments: [("microphone", 100, 900)],
            offsetMs: 250,
            mergeGapMs: 1000
        )
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].localStartMs, 100)   // track-local for slicing
        XCTAssertEqual(turns[0].localEndMs, 900)
        XCTAssertEqual(turns[0].absStartMs, 350)     // meeting-absolute for the word
        XCTAssertEqual(turns[0].absEndMs, 1150)
    }

    func testDropsZeroLengthSegments() {
        let turns = TranscriptionService.buildTurns(
            segments: [("system:S1", 500, 500), ("system:S1", 600, 400)],
            offsetMs: 0,
            mergeGapMs: 1000
        )
        XCTAssertTrue(turns.isEmpty)
    }

    // MARK: - assemblePerTurn

    func testAssembleSortsAndLabels() {
        let words = [
            WordTimestamp(word: "and margins held", startMs: 3000, endMs: 4000, confidence: 1, speakerId: "system:S1"),
            WordTimestamp(word: "so the numbers came in", startMs: 0, endMs: 2000, confidence: 1, speakerId: "microphone"),
        ]
        let speakers = [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system:S1", label: "Sara"),
        ]

        let result = MeetingTranscriptFinalizer.assemblePerTurn(turns: words, speakers: speakers)

        // Sorted by start time.
        XCTAssertEqual(result.words.map(\.word), ["so the numbers came in", "and margins held"])
        // Readable transcript uses display labels in chronological order.
        XCTAssertEqual(result.rawTranscript, "Me: so the numbers came in\n\nSara: and margins held")
        XCTAssertEqual(result.durationMs, 4000)
        XCTAssertFalse(result.diarizationSegments.isEmpty)
        XCTAssertEqual(result.speakers.count, 2)
    }

    func testAssembleFallsBackToSpeakerIdWhenNoLabel() {
        let words = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 1000, confidence: 1, speakerId: "system:S9"),
        ]
        let result = MeetingTranscriptFinalizer.assemblePerTurn(turns: words, speakers: [])
        XCTAssertEqual(result.rawTranscript, "system:S9: hello")
    }
}
