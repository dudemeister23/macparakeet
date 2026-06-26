import XCTest

@testable import MacParakeetCore

/// Tests the in-place "Detect speakers" merge: re-tagging an already-finalized,
/// undiarized meeting transcript's words with diarized speaker ids without
/// re-running ASR.
final class MeetingTranscriptApplyDiarizationTests: XCTestCase {
    private func word(_ text: String, _ start: Int, _ end: Int, speaker: String) -> WordTimestamp {
        WordTimestamp(word: text, startMs: start, endMs: end, confidence: 0.9, speakerId: speaker)
    }

    func testReTagsSystemWordsKeepsMicrophoneWords() {
        // Undiarized meeting: system words tagged "system", mic words "microphone".
        let words = [
            word("hi", 0, 500, speaker: AudioSource.system.rawValue),
            word("there", 600, 1000, speaker: AudioSource.system.rawValue),
            word("yes", 1500, 1900, speaker: AudioSource.microphone.rawValue),
            word("okay", 3000, 3500, speaker: AudioSource.system.rawValue),
        ]
        let diarization = MeetingTranscriptFinalizer.SystemDiarization(
            speakers: [
                SpeakerInfo(id: "system:S1", label: "Sara"),
                SpeakerInfo(id: "system:S2", label: "Others 2"),
            ],
            segments: [
                SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 1200),
                SpeakerSegment(speakerId: "system:S2", startMs: 2900, endMs: 3600),
            ]
        )

        let result = MeetingTranscriptFinalizer.applyDiarization(
            toExistingWords: words,
            systemDiarization: diarization
        )

        let byText = Dictionary(uniqueKeysWithValues: result.words.map { ($0.word, $0.speakerId) })
        // System words re-tagged to diarized ids by time overlap.
        XCTAssertEqual(byText["hi"], "system:S1")
        XCTAssertEqual(byText["there"], "system:S1")
        XCTAssertEqual(byText["okay"], "system:S2")
        // Microphone word untouched.
        XCTAssertEqual(byText["yes"], AudioSource.microphone.rawValue)

        // Speakers carry the recognized/diarized labels; segments rebuilt.
        XCTAssertTrue(result.speakers.contains { $0.id == "system:S1" && $0.label == "Sara" })
        XCTAssertFalse(result.diarizationSegments.isEmpty)
        // Words stay time-ordered.
        XCTAssertEqual(result.words.map(\.startMs), result.words.map(\.startMs).sorted())
    }

    func testNoSystemWordsLeavesWordsUntouched() {
        let words = [
            word("solo", 0, 500, speaker: AudioSource.microphone.rawValue),
        ]
        let diarization = MeetingTranscriptFinalizer.SystemDiarization(
            speakers: [SpeakerInfo(id: "system:S1", label: "Sara")],
            segments: [SpeakerSegment(speakerId: "system:S1", startMs: 0, endMs: 500)]
        )
        let result = MeetingTranscriptFinalizer.applyDiarization(
            toExistingWords: words, systemDiarization: diarization
        )
        XCTAssertEqual(result.words.first?.speakerId, AudioSource.microphone.rawValue)
    }
}
