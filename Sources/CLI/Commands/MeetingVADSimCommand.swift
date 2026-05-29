import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli meeting-vad-sim <audio>` — headlessly replay the meeting
/// live-preview chunking path on an audio file and compare the fixed 5s strategy
/// against VAD speech-boundary chunking. Dev/agent tool for Phase 0 of the
/// VAD-guided live chunking plan: measures chunk boundaries on real speech and
/// the realtime factor that decides whether VAD can run inline in the capture
/// task. Does not exercise live capture or the GUI.
struct MeetingVADSimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meeting-vad-sim",
        abstract: "Replay meeting live-chunking (fixed vs VAD) on an audio file and report boundaries + realtime factor."
    )

    @Argument(help: "Path to an audio file (wav/m4a/mp3/caf/aiff).")
    var audioPath: String

    @Option(name: .long, help: "Strategy: fixed | vad | both. Default: both.")
    var mode: String = "both"

    @Option(name: .long, help: "Ingest batch size in milliseconds (capture cadence). Default: 100.")
    var batchMs: Int = 100

    @Flag(name: .long, help: "Print every chunk boundary (default caps the list).")
    var allChunks: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    func run() async throws {
        let url = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
        let modes = try parseModes()
        let batchSamples = max(1, batchMs) * 16  // 16 samples per ms @ 16kHz

        let samples = try MeetingVADChunkingSimulator.loadSamples16k(url: url)

        var reports: [MeetingVADChunkingSimulator.Report] = []
        for m in modes {
            reports.append(await MeetingVADChunkingSimulator.simulate(
                samples16k: samples, mode: m, batchSamples: batchSamples))
        }

        if json {
            try printJSON(reports.map(JSONReport.init))
        } else {
            for report in reports { printHuman(report) }
            if reports.count > 1 { printComparison(reports) }
        }
    }

    private func parseModes() throws -> [MeetingVADChunkingSimulator.Mode] {
        switch mode.lowercased() {
        case "fixed": return [.fixed]
        case "vad": return [.vad]
        case "both": return [.fixed, .vad]
        default: throw ValidationError("--mode must be one of: fixed, vad, both")
        }
    }

    private func printHuman(_ r: MeetingVADChunkingSimulator.Report) {
        print("")
        print("── mode: \(r.mode) " + String(repeating: "─", count: max(0, 40 - r.mode.count)))
        if r.mode == "vad" && !r.vadAvailable {
            print("  VAD model not cached — live path would fall back to fixed.")
            print("  (Run onboarding / download the Silero VAD model, then retry.)")
            return
        }
        let durS = Double(r.audioDurationMs) / 1000.0
        print(String(format: "  audio duration   : %.1fs (%d ingest batches @ %dms)",
                     durS, r.ingestBatchCount, batchMs))
        print(String(format: "  processing time  : %.3fs  →  %.0f× realtime",
                     r.processingSeconds, r.realtimeFactor))
        print(String(format: "  per-ingest (ms)  : p50=%.3f  p99=%.3f  max=%.3f",
                     r.perIngestMsP50, r.perIngestMsP99, r.perIngestMsMax))
        let durations = r.chunks.map(\.durationMs)
        let avgDur = durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count
        print("  chunks emitted   : \(r.chunks.count)  (avg \(avgDur)ms)")
        if r.mode == "vad" {
            print("  vad diagnostics  : speechEnds=\(r.speechEndEvents) forceEmits=\(r.forceEmits) "
                  + "droppedSilence=\(r.droppedSilenceWindows) vadErrors=\(r.vadErrors) "
                  + "fellBackToFixed=\(r.fellBackToFixed)")
        }
        printBoundaries(r.chunks)
    }

    private func printBoundaries(_ chunks: [MeetingVADChunkingSimulator.ChunkSummary]) {
        guard !chunks.isEmpty else { return }
        let cap = 20
        let shown = allChunks ? chunks : Array(chunks.prefix(cap))
        print("  boundaries [startMs→endMs (durMs)]:")
        for c in shown {
            print(String(format: "    #%-3d %7d → %7d  (%5dms)", c.index, c.startMs, c.endMs, c.durationMs))
        }
        if !allChunks && chunks.count > cap {
            print("    … \(chunks.count - cap) more (use --all-chunks)")
        }
    }

    private func printComparison(_ reports: [MeetingVADChunkingSimulator.Report]) {
        guard let fixed = reports.first(where: { $0.mode == "fixed" }),
              let vad = reports.first(where: { $0.mode == "vad" }), vad.vadAvailable else { return }
        print("")
        print("── comparison ───────────────────────────")
        print("  chunks      : fixed=\(fixed.chunks.count)  vad=\(vad.chunks.count)")
        print(String(format: "  realtime    : fixed=%.0f×  vad=%.0f×", fixed.realtimeFactor, vad.realtimeFactor))
        print(String(format: "  vad overhead: %.3fs extra processing vs fixed",
                     max(0, vad.processingSeconds - fixed.processingSeconds)))
        // Decision hint for #2 (inline vs decouple).
        if vad.realtimeFactor >= 5 {
            print(String(format: "  → VAD runs at %.0f× realtime; inline-in-capture is safe (queue can't back up).",
                         vad.realtimeFactor))
        } else if vad.realtimeFactor > 0 {
            print(String(format: "  → VAD only %.1f× realtime; consider decoupling VAD onto its own task.",
                         vad.realtimeFactor))
        }
    }

    private struct JSONReport: Encodable {
        let mode: String
        let vadAvailable: Bool
        let audioDurationMs: Int
        let ingestBatchCount: Int
        let batchSamples: Int
        let chunkCount: Int
        let processingSeconds: Double
        let realtimeFactor: Double
        let perIngestMsP50: Double
        let perIngestMsP99: Double
        let perIngestMsMax: Double
        let chunksEmitted: Int
        let speechEndEvents: Int
        let forceEmits: Int
        let droppedSilenceWindows: Int
        let vadErrors: Int
        let fellBackToFixed: Bool
        let chunks: [Chunk]

        struct Chunk: Encodable {
            let index: Int
            let startMs: Int
            let endMs: Int
            let durationMs: Int
            let sampleCount: Int
        }

        init(_ r: MeetingVADChunkingSimulator.Report) {
            mode = r.mode
            vadAvailable = r.vadAvailable
            audioDurationMs = r.audioDurationMs
            ingestBatchCount = r.ingestBatchCount
            batchSamples = r.batchSamples
            chunkCount = r.chunks.count
            processingSeconds = r.processingSeconds
            realtimeFactor = r.realtimeFactor
            perIngestMsP50 = r.perIngestMsP50
            perIngestMsP99 = r.perIngestMsP99
            perIngestMsMax = r.perIngestMsMax
            chunksEmitted = r.chunksEmitted
            speechEndEvents = r.speechEndEvents
            forceEmits = r.forceEmits
            droppedSilenceWindows = r.droppedSilenceWindows
            vadErrors = r.vadErrors
            fellBackToFixed = r.fellBackToFixed
            chunks = r.chunks.map {
                Chunk(index: $0.index, startMs: $0.startMs, endMs: $0.endMs,
                      durationMs: $0.durationMs, sampleCount: $0.sampleCount)
            }
        }
    }
}
