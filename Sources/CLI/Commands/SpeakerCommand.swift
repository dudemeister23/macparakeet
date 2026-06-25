import ArgumentParser
import AVFoundation
import Foundation
import MacParakeetCore

/// Manage enrolled speaker voice profiles and test recognition headlessly.
///
/// This is the validation surface for native speaker recognition: enroll a few
/// known speakers from audio, then `recognize` a meeting and inspect how
/// cleanly the diarized clusters match the enrolled profiles (distances and
/// margins). Profiles are shared with the app (same database + `wespeaker_v2`
/// embedding space).
struct SpeakerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speaker",
        abstract: "Manage enrolled speaker voice profiles and test recognition.",
        subcommands: [
            SpeakerEnrollCommand.self,
            SpeakerListCommand.self,
            SpeakerRecognizeCommand.self,
            SpeakerRemoveCommand.self,
        ]
    )
}

// MARK: - enroll

struct SpeakerEnrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll",
        abstract: "Enroll a speaker from an audio clip (assumed single-speaker)."
    )

    @Argument(help: "Display name for the speaker, e.g. \"Sara\".")
    var name: String

    @Argument(help: "Path to an audio file of this speaker (wav/m4a/mp3/caf/aiff).")
    var file: String

    @Option(name: .long, help: "Start offset in seconds to enroll from. Default: 0.")
    var start: Double = 0

    @Option(name: .long, help: "Seconds of audio to use from --start. Default: whole file.")
    var duration: Double?

    @Flag(name: .long, help: "Replace an existing profile with the same name instead of adding a second.")
    var replace: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() async throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("Audio file not found: \(url.path)")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ValidationError("Speaker name cannot be empty.") }

        let allSamples = try MeetingVADChunkingSimulator.loadSamples16k(url: url)
        let samples = Self.slice(allSamples, start: start, duration: duration, sampleRate: 16_000)
        let seconds = Double(samples.count) / 16_000
        guard seconds >= 1 else {
            throw ValidationError(String(format: "Need at least 1s of audio to enroll; got %.2fs.", seconds))
        }

        let embedder = SpeakerEmbeddingService()
        try await embedder.prepareModels { FileHandle.standardError.write(Data(("  " + $0 + "\n").utf8)) }
        let embedding = try await embedder.embed(samples: samples)

        let repo = try SpeakerProfileRepository(dbQueue: DatabaseManager(path: resolvedDatabasePath(database)).dbQueue)
        if replace, let existing = try repo.fetchAll().first(where: {
            $0.name.compare(trimmedName, options: .caseInsensitive) == .orderedSame
        }) {
            var updated = existing
            updated.embedding = embedding
            updated.enrolledSeconds = seconds
            updated.updatedAt = Date()
            try repo.save(updated)
            print(String(format: "Updated profile \"%@\" from %.1fs of audio.", trimmedName, seconds))
        } else {
            let profile = SpeakerProfile(name: trimmedName, embedding: embedding, enrolledSeconds: seconds)
            try repo.save(profile)
            print(String(format: "Enrolled \"%@\" from %.1fs of audio (id %@).",
                         trimmedName, seconds, profile.id.uuidString))
        }
    }

    static func slice(_ samples: [Float], start: Double, duration: Double?, sampleRate: Int) -> [Float] {
        let startIdx = max(0, min(samples.count, Int(start * Double(sampleRate))))
        let endIdx: Int
        if let duration {
            endIdx = max(startIdx, min(samples.count, startIdx + Int(duration * Double(sampleRate))))
        } else {
            endIdx = samples.count
        }
        return Array(samples[startIdx..<endIdx])
    }
}

// MARK: - list

struct SpeakerListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List enrolled speaker profiles."
    )

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() async throws {
        let repo = try SpeakerProfileRepository(dbQueue: DatabaseManager(path: resolvedDatabasePath(database)).dbQueue)
        let profiles = try repo.fetchAll()
        guard !profiles.isEmpty else {
            print("No enrolled speakers. Use `macparakeet-cli speaker enroll <name> <file>`.")
            return
        }
        print("\(profiles.count) enrolled speaker(s):")
        for p in profiles {
            print(String(format: "  %@  (%.1fs enrolled, %d-d, id %@)",
                         p.name, p.enrolledSeconds, p.embedding.count, p.id.uuidString))
        }
    }
}

// MARK: - remove

struct SpeakerRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an enrolled speaker profile by name or id."
    )

    @Argument(help: "Speaker name or profile id to remove.")
    var nameOrID: String

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() async throws {
        let repo = try SpeakerProfileRepository(dbQueue: DatabaseManager(path: resolvedDatabasePath(database)).dbQueue)
        let profiles = try repo.fetchAll()
        let matches = profiles.filter {
            $0.id.uuidString.compare(nameOrID, options: .caseInsensitive) == .orderedSame
                || $0.name.compare(nameOrID, options: .caseInsensitive) == .orderedSame
        }
        guard let target = matches.first else {
            throw ValidationError("No profile matching \"\(nameOrID)\".")
        }
        if matches.count > 1 {
            FileHandle.standardError.write(Data("Multiple profiles named \"\(nameOrID)\"; removing the first.\n".utf8))
        }
        _ = try repo.delete(id: target.id)
        print("Removed \"\(target.name)\".")
    }
}

// MARK: - recognize

struct SpeakerRecognizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recognize",
        abstract: "Diarize an audio file and match each speaker against enrolled profiles."
    )

    @Argument(help: "Path to an audio file (wav/m4a/mp3/caf/aiff).")
    var file: String

    @Option(name: .long, help: "Max cosine distance for a match. Lower = stricter. Default: 0.5.")
    var maxDistance: Float = SpeakerMatcher.defaultMaxDistance

    @Option(name: .long, help: "Start offset in seconds. With --duration, recognizes only that window (useful for long meetings).")
    var start: Double = 0

    @Option(name: .long, help: "Seconds of audio to recognize from --start. Default: to end of file.")
    var duration: Double?

    @Option(name: .long, help: "Exact expected speaker count for diarization.")
    var speakers: Int?

    @Option(name: .long, help: "Minimum expected speaker count.")
    var speakerMin: Int?

    @Option(name: .long, help: "Maximum expected speaker count.")
    var speakerMax: Int?

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() async throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("Audio file not found: \(url.path)")
        }

        let repo = try SpeakerProfileRepository(dbQueue: DatabaseManager(path: resolvedDatabasePath(database)).dbQueue)
        let profiles = try repo.fetchAll()
        guard !profiles.isEmpty else {
            print("No enrolled speakers to match against. Enroll some first.")
            return
        }

        // Load audio; optionally trim to [--start, --start+--duration] so a long
        // meeting can be validated on a short window instead of diarizing the
        // whole file. When trimming, diarization runs on a temp WAV of the same
        // samples we embed, keeping the two consistent.
        var samples = try MeetingVADChunkingSimulator.loadSamples16k(url: url)
        var diarizeURL = url
        var tempURL: URL?
        if start > 0 || duration != nil {
            samples = SpeakerEnrollCommand.slice(samples, start: start, duration: duration, sampleRate: 16_000)
            guard samples.count >= 16_000 else {
                throw ValidationError("Trimmed window has too little audio (need ≥ 1s).")
            }
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("spk_recognize_\(UUID().uuidString).wav")
            try Self.writeMono16kWav(samples, to: tmp)
            diarizeURL = tmp
            tempURL = tmp
        }
        defer { if let tempURL { try? FileManager.default.removeItem(at: tempURL) } }

        FileHandle.standardError.write(Data("Diarizing…\n".utf8))
        let diarizer: DiarizationService
        if let constraint = Self.constraint(exact: speakers, min: speakerMin, max: speakerMax) {
            diarizer = DiarizationService(speakerConstraint: constraint)
        } else {
            diarizer = DiarizationService()
        }
        let diarization = try await diarizer.diarize(audioURL: diarizeURL)
        guard !diarization.speakers.isEmpty else {
            print("No speakers detected.")
            return
        }

        let embedder = SpeakerEmbeddingService()
        try await embedder.prepareModels { FileHandle.standardError.write(Data(("  " + $0 + "\n").utf8)) }

        print("Diarized \(diarization.speakers.count) speaker(s) in \(url.lastPathComponent):\n")

        for speaker in diarization.speakers {
            let segs = diarization.segments.filter { $0.speakerId == speaker.id }
            let speechMs = segs.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
            let clusterSamples = SpeakerRecognizer.gatherSamples(
                segments: segs.sorted { ($0.endMs - $0.startMs) > ($1.endMs - $1.startMs) },
                from: samples,
                sampleRate: 16_000,
                maxSamples: 30 * 16_000
            )
            guard clusterSamples.count >= 16_000 else {
                print(String(format: "  %@  %5.1fs  → (too little audio to match)", speaker.id, Double(speechMs) / 1000))
                continue
            }
            let vector = try await embedder.embed(samples: clusterSamples)
            let ranked = profiles
                .map { (name: $0.name, distance: SpeakerMatcher.cosineDistance(vector, $0.embedding)) }
                .sorted { $0.distance < $1.distance }
            let best = ranked.first
            let label: String
            if let best, best.distance <= maxDistance {
                label = String(format: "→ %@   (distance %.3f)", best.name, best.distance)
            } else if let best {
                label = String(format: "→ (anonymous)   nearest: %@ %.3f > %.2f", best.name, best.distance, maxDistance)
            } else {
                label = "→ (anonymous)"
            }
            print(String(format: "  %@  %5.1fs  %@", speaker.id, Double(speechMs) / 1000, label))
            let table = ranked.map { String(format: "%@ %.3f", $0.name, $0.distance) }.joined(separator: "  |  ")
            print("        \(table)")
        }
        print(String(format: "\nthreshold: max distance %.2f", maxDistance))
    }

    static func constraint(exact: Int?, min: Int?, max: Int?) -> SpeakerDiarizationConstraint? {
        if let exact { return .exact(exact) }
        if min != nil || max != nil { return .range(min: min, max: max) }
        return nil
    }

    /// Write mono 16 kHz Float samples to a WAV file for diarization input.
    static func writeMono16kWav(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw ValidationError("Could not create 16 kHz mono audio format.")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunk = 1 << 16
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
                throw ValidationError("Could not allocate audio buffer.")
            }
            buffer.frameLength = AVAudioFrameCount(n)
            if let dst = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!.advanced(by: offset), count: n)
                }
            }
            try file.write(from: buffer)
            offset += n
        }
    }
}
