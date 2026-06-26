import AVFoundation
import XCTest

@testable import MacParakeetCore

final class SpeakerEnrollmentFromRecordingTests: XCTestCase {
    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spk-enroll-\(UUID().uuidString).wav")
    }

    override func tearDownWithError() throws {
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
    }

    private func writeWav(seconds: Double) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let count = Int(seconds * 16_000)
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let channel = buffer.floatChannelData![0]
        for i in 0..<count { channel[i] = Float(i % 100) / 100.0 - 0.5 }  // benign ramp
        try file.write(from: buffer)
    }

    private func makeTranscription(
        filePath: String?,
        segments: [DiarizationSegmentRecord]?
    ) -> Transcription {
        Transcription(
            fileName: "meeting.m4a",
            filePath: filePath,
            diarizationSegments: segments,
            status: .completed
        )
    }

    func testExtractsRequestedSpeakerWindow() throws {
        try writeWav(seconds: 3)
        let t = makeTranscription(
            filePath: tempURL.path,
            segments: [
                DiarizationSegmentRecord(speakerId: "system:S1", startMs: 0, endMs: 2000),
                DiarizationSegmentRecord(speakerId: "system:S2", startMs: 2000, endMs: 3000),
            ]
        )

        let (samples, seconds) = try SpeakerEnrollmentFromRecording.extractSamples(
            transcription: t, speakerId: "system:S1"
        )
        XCTAssertEqual(seconds, 2.0, accuracy: 0.1)
        XCTAssertEqual(samples.count, 32_000, accuracy: 1_600)  // ~2s @ 16k
    }

    func testAudioUnavailableWhenFilePathNil() throws {
        let t = makeTranscription(filePath: nil, segments: [
            DiarizationSegmentRecord(speakerId: "system:S1", startMs: 0, endMs: 2000),
        ])
        XCTAssertThrowsError(try SpeakerEnrollmentFromRecording.extractSamples(transcription: t, speakerId: "system:S1")) {
            XCTAssertEqual($0 as? SpeakerEnrollmentFromRecording.ExtractionError, .audioUnavailable)
        }
    }

    func testAudioUnavailableWhenFileMissing() throws {
        let t = makeTranscription(filePath: "/nope/does-not-exist.wav", segments: [
            DiarizationSegmentRecord(speakerId: "system:S1", startMs: 0, endMs: 2000),
        ])
        XCTAssertThrowsError(try SpeakerEnrollmentFromRecording.extractSamples(transcription: t, speakerId: "system:S1")) {
            XCTAssertEqual($0 as? SpeakerEnrollmentFromRecording.ExtractionError, .audioUnavailable)
        }
    }

    func testSegmentsMissing() throws {
        try writeWav(seconds: 2)
        let t = makeTranscription(filePath: tempURL.path, segments: nil)
        XCTAssertThrowsError(try SpeakerEnrollmentFromRecording.extractSamples(transcription: t, speakerId: "system:S1")) {
            XCTAssertEqual($0 as? SpeakerEnrollmentFromRecording.ExtractionError, .segmentsMissing)
        }
    }

    func testSpeakerNotFound() throws {
        try writeWav(seconds: 2)
        let t = makeTranscription(filePath: tempURL.path, segments: [
            DiarizationSegmentRecord(speakerId: "system:S2", startMs: 0, endMs: 2000),
        ])
        XCTAssertThrowsError(try SpeakerEnrollmentFromRecording.extractSamples(transcription: t, speakerId: "system:S1")) {
            XCTAssertEqual($0 as? SpeakerEnrollmentFromRecording.ExtractionError, .speakerNotFound)
        }
    }

    func testTooShort() throws {
        try writeWav(seconds: 3)
        let t = makeTranscription(filePath: tempURL.path, segments: [
            DiarizationSegmentRecord(speakerId: "system:S1", startMs: 0, endMs: 400),  // 0.4s < 1s floor
        ])
        XCTAssertThrowsError(try SpeakerEnrollmentFromRecording.extractSamples(transcription: t, speakerId: "system:S1")) { error in
            guard case SpeakerEnrollmentFromRecording.ExtractionError.tooShort = error else {
                return XCTFail("expected .tooShort, got \(error)")
            }
        }
    }
}
