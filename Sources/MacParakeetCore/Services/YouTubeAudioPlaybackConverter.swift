import Darwin
import Foundation
import os

/// Errors specific to playback-conversion. Conversion failures are
/// non-fatal at the transcription-pipeline level — they just mean the
/// saved audio file stays in its original format and the in-app scrubber
/// will be inert for that file (the user can still use Show Video, which
/// re-extracts a streamable URL via yt-dlp).
public enum YouTubeAudioPlaybackConverterError: Error, Sendable {
    case ffmpegUnavailable(String)
    case conversionFailed(String)
    case sourceMissing(String)
}

public protocol YouTubeAudioPlaybackConverting: Sendable {
    /// Convert `inputPath` to an AVPlayer-compatible `.m4a` if needed.
    /// Returns the path of the playable file. If the input is already
    /// playable, returns the input path unchanged. The caller owns the
    /// source file's lifetime — this method does **not** delete the
    /// source after a successful conversion, since the safe deletion
    /// point is after the caller has persisted the new path.
    func convertToPlayableM4AIfNeeded(inputPath: String) async throws -> String
}

/// Transcodes yt-dlp downloads that AVPlayer can't decode (WebM/Opus/Ogg)
/// into a `.m4a` AAC file for the in-app audio scrubber. Built so we can
/// keep using yt-dlp's higher-bitrate Opus stream for transcription (which
/// measurably improves Parakeet accuracy — see issue #237) without
/// stranding the saved audio in a container macOS can't play.
public final class YouTubeAudioPlaybackConverter: YouTubeAudioPlaybackConverting, Sendable {
    public init() {}

    /// Extensions yt-dlp produces that AVPlayer on macOS cannot decode.
    /// AVFoundation has no native WebM container demuxer and no native
    /// Opus/Vorbis decoder; the resulting `AVPlayer` is silent at play()
    /// with no surfaced error. See memory: reference_avplayer_codec_limits.
    /// `weba` is yt-dlp's audio-only WebM extension.
    public static let unplayableExtensions: Set<String> = [
        "webm", "weba", "opus", "ogg", "mkv"
    ]

    /// Cheap pre-check so callers can avoid spinning up an ffmpeg process
    /// for files that are already playable.
    public static func needsConversion(forPath path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return unplayableExtensions.contains(ext)
    }

    private let logger = Logger(subsystem: "com.macparakeet", category: "PlaybackConverter")

    public func convertToPlayableM4AIfNeeded(inputPath: String) async throws -> String {
        guard Self.needsConversion(forPath: inputPath) else {
            return inputPath
        }

        let inputURL = URL(fileURLWithPath: inputPath)

        // Write next to the source so storage retention rules (clear cache,
        // Settings > Downloaded YouTube audio) keep applying without any
        // path-rewriting elsewhere in the app.
        let outputURL = inputURL
            .deletingPathExtension()
            .appendingPathExtension("m4a")

        // Early-out for the race window between the post-STT converter and
        // the on-open lazy-migration converter: if a previous run already
        // produced the m4a and the source webm is gone, just return the
        // m4a path. Avoids a redundant ffmpeg invocation.
        let outputExists = FileManager.default.fileExists(atPath: outputURL.path)
        let inputExists = FileManager.default.fileExists(atPath: inputPath)
        if outputExists, !inputExists {
            return outputURL.path
        }
        guard inputExists else {
            throw YouTubeAudioPlaybackConverterError.sourceMissing(inputPath)
        }

        let ffmpegPath = try findFFmpeg()

        // ffmpeg arguments: AAC 192k mono/stereo (passthrough channel
        // layout), faststart for streaming-friendly seeks, no video. 192k
        // is well above the WAV downsample floor Parakeet sees, so any
        // re-transcribe from this m4a stays within accuracy noise. We
        // explicitly drop video tracks (`-vn`) because yt-dlp's webm may
        // still contain a thumbnail image stream that AAC encoders won't
        // accept.
        //
        // Concurrency: write to a UUID-tagged temp path, then atomically
        // move into the final m4a slot. If the post-STT converter and the
        // on-open lazy-migration race on the same source, both produce
        // deterministic identical bytes; the last move wins. AVPlayer
        // never observes a partial write because it isn't pointed at the
        // m4a path until conversion completes.
        let tempOutputURL = Self.temporaryOutputURL(for: outputURL)

        try await runFFmpegWithDyldFallback(
            primaryPath: ffmpegPath,
            inputURL: inputURL,
            outputURL: tempOutputURL
        )

        // Sanity check: ffmpeg can exit 0 yet write an empty file (rare,
        // but the cost of "we already deleted the source webm" makes the
        // check worth a stat call).
        let outputSize = (try? FileManager.default
            .attributesOfItem(atPath: tempOutputURL.path)[.size] as? Int) ?? 0
        guard outputSize > 0 else {
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw YouTubeAudioPlaybackConverterError.conversionFailed(
                "FFmpeg produced an empty output file"
            )
        }

        // Truly atomic commit via POSIX `rename(2)`: if the destination
        // exists it is replaced in a single syscall, with no window in
        // which the file is missing. The earlier
        // "fileExists → removeItem → moveItem" sequence had a real (if
        // tiny) gap where a crash between the two FileManager calls could
        // leave no m4a at all, and a concurrent converter could delete
        // a valid output we'd just produced. `rename(2)` is atomic on
        // POSIX systems for paths on the same filesystem (which is the
        // case here — both live in the YouTube downloads directory).
        if rename(tempOutputURL.path, outputURL.path) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tempOutputURL)
            throw YouTubeAudioPlaybackConverterError.conversionFailed(
                "Failed to commit transcoded audio: \(err)"
            )
        }

        return outputURL.path
    }

    /// Build the ffmpeg argument vector. Exposed for testing.
    public static func ffmpegArguments(inputPath: String, outputPath: String) -> [String] {
        [
            "-nostdin",
            "-i", inputPath,
            "-vn",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            "-y",
            outputPath
        ]
    }

    static func temporaryOutputURL(for outputURL: URL, uuid: UUID = UUID()) -> URL {
        outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(outputURL.deletingPathExtension().lastPathComponent).tmp-\(uuid.uuidString)"
            )
            .appendingPathExtension(outputURL.pathExtension)
    }

    // MARK: - Private

    private func findFFmpeg() throws -> String {
        do {
            return try BinaryBootstrap.requireRuntimeFFmpegPath()
        } catch {
            throw YouTubeAudioPlaybackConverterError.ffmpegUnavailable(
                "FFmpeg is unavailable for this runtime."
            )
        }
    }

    /// Run ffmpeg, falling back to system ffmpeg on dyld / Team-ID-mismatch
    /// failures. Mirrors `AudioFileConverter`'s retry so that a user whose
    /// bundled ffmpeg can't load its dylibs (memory:
    /// `feedback_duplicate_codesign_cert_tcc.md` and the PyInstaller note
    /// in CLAUDE.md) doesn't end up with a successful transcript but a
    /// silently broken playback file — both paths now have the same
    /// fallback envelope.
    private func runFFmpegWithDyldFallback(
        primaryPath: String,
        inputURL: URL,
        outputURL: URL
    ) async throws {
        do {
            try await runFFmpeg(
                ffmpegPath: primaryPath,
                inputURL: inputURL,
                outputURL: outputURL
            )
        } catch let error as YouTubeAudioPlaybackConverterError {
            guard case .conversionFailed(let reason) = error,
                  reason.contains("dyld") || reason.contains("Library not loaded"),
                  let fallbackPath = BinaryBootstrap.findSystemFFmpeg(),
                  fallbackPath != primaryPath
            else {
                throw error
            }
            logger.info("Bundled ffmpeg failed with dyld error; retrying via system ffmpeg at \(fallbackPath, privacy: .public)")
            try await runFFmpeg(
                ffmpegPath: fallbackPath,
                inputURL: inputURL,
                outputURL: outputURL
            )
        }
    }

    private func runFFmpeg(
        ffmpegPath: String,
        inputURL: URL,
        outputURL: URL
    ) async throws {
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = Self.ffmpegArguments(
            inputPath: inputURL.path,
            outputPath: outputURL.path
        )

        // Mirror AudioFileConverter's stderr handling — ffmpeg's verbose
        // progress can fill the 64KB pipe buffer and deadlock both ends.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        let stderrURL = tempDir
            .appendingPathComponent("ffmpeg-playback-stderr-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        try process.run()
        try await ChildProcessWaiter.waitUntilExit(
            process,
            timeout: 600,
            timeoutError: YouTubeAudioPlaybackConverterError.conversionFailed(
                "FFmpeg playback conversion timed out"
            )
        )

        if process.terminationStatus != 0 {
            try? stderrHandle.synchronize()
            let stderrStr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "Unknown error"
            throw YouTubeAudioPlaybackConverterError.conversionFailed(
                Self.tailForError(stderrStr)
            )
        }

        succeeded = true
    }

    /// ffmpeg's startup banner is long; surface only the final lines where
    /// the actual error lives. Matches AudioFileConverter's behavior so
    /// telemetry stays consistent if/when we add it.
    private static func tailForError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 384
        guard trimmed.count > limit else { return trimmed }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -limit)
        return "...\(trimmed[start...])"
    }
}
