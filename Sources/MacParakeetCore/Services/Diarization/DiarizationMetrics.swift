import Foundation

public struct LabeledSegment: Codable, Equatable, Sendable {
    public let recordingId: String?
    public let speakerId: String
    public let startMs: Int
    public let endMs: Int

    public init(recordingId: String? = nil, speakerId: String, startMs: Int, endMs: Int) {
        self.recordingId = recordingId
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
    }

    public init(_ segment: SpeakerSegment) {
        self.init(
            speakerId: segment.speakerId,
            startMs: segment.startMs,
            endMs: segment.endMs
        )
    }
}

public struct DiarizationScoringOptions: Codable, Equatable, Sendable {
    public var collarMs: Int
    public var skipOverlap: Bool

    public static let `default` = Self()

    public init(collarMs: Int = 0, skipOverlap: Bool = false) {
        self.collarMs = max(0, collarMs)
        self.skipOverlap = skipOverlap
    }
}

public struct DERBreakdown: Codable, Equatable, Sendable {
    public let missedMs: Int
    public let falseAlarmMs: Int
    public let confusionMs: Int
    public let totalReferenceMs: Int
    public let der: Double
    public let collarMs: Int
    public let skipOverlap: Bool

    public init(
        missedMs: Int,
        falseAlarmMs: Int,
        confusionMs: Int,
        totalReferenceMs: Int,
        der: Double,
        collarMs: Int = 0,
        skipOverlap: Bool = false
    ) {
        self.missedMs = missedMs
        self.falseAlarmMs = falseAlarmMs
        self.confusionMs = confusionMs
        self.totalReferenceMs = totalReferenceMs
        self.der = der
        self.collarMs = collarMs
        self.skipOverlap = skipOverlap
    }
}

public enum DiarizationMetrics {
    private struct Interval {
        let startMs: Int
        let endMs: Int
    }

    private struct SpeakerPair: Hashable {
        let reference: String
        let hypothesis: String
    }

    /// Approximate NIST md-eval-style DER with exact millisecond regions.
    /// Overlap regions use speaker-time accounting unless `skipOverlap` is set.
    public static func der(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> DERBreakdown {
        der(reference: reference, hypothesis: hypothesis, options: .default)
    }

    public static func der(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        options: DiarizationScoringOptions
    ) -> DERBreakdown {
        let reference = normalized(reference)
        let hypothesis = normalized(hypothesis)
        let regions = scoredRegions(reference: reference, hypothesis: hypothesis, options: options)
        let mapping = greedySpeakerMapping(reference: reference, hypothesis: hypothesis, regions: regions)

        var missedMs = 0
        var falseAlarmMs = 0
        var confusionMs = 0
        var totalReferenceMs = 0

        for region in regions {
            let activeReference = activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs)
            let activeHypothesis = activeSpeakers(in: hypothesis, startMs: region.startMs, endMs: region.endMs)
            let referenceCount = activeReference.count
            let hypothesisCount = activeHypothesis.count
            let durationMs = region.endMs - region.startMs

            let correctCount = activeHypothesis.reduce(into: Set<String>()) { matches, hypothesisSpeaker in
                guard let referenceSpeaker = mapping[hypothesisSpeaker],
                      activeReference.contains(referenceSpeaker)
                else {
                    return
                }
                matches.insert(referenceSpeaker)
            }
            .count

            missedMs += max(0, referenceCount - hypothesisCount) * durationMs
            falseAlarmMs += max(0, hypothesisCount - referenceCount) * durationMs
            confusionMs += max(0, min(referenceCount, hypothesisCount) - correctCount) * durationMs
            totalReferenceMs += referenceCount * durationMs
        }

        return DERBreakdown(
            missedMs: missedMs,
            falseAlarmMs: falseAlarmMs,
            confusionMs: confusionMs,
            totalReferenceMs: totalReferenceMs,
            der: derValue(
                missedMs: missedMs,
                falseAlarmMs: falseAlarmMs,
                confusionMs: confusionMs,
                totalReferenceMs: totalReferenceMs
            ),
            collarMs: options.collarMs,
            skipOverlap: options.skipOverlap
        )
    }

    public static func coverage(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> Double {
        coverage(reference: reference, hypothesis: hypothesis, options: .default)
    }

    public static func coverage(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        options: DiarizationScoringOptions
    ) -> Double {
        let reference = normalized(reference)
        let hypothesis = normalized(hypothesis)
        let regions = scoredRegions(reference: reference, hypothesis: hypothesis, options: options)

        var totalReferenceMs = 0
        var coveredMs = 0
        for region in regions {
            let hasReference = !activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs).isEmpty
            guard hasReference else { continue }
            let durationMs = region.endMs - region.startMs
            totalReferenceMs += durationMs
            if !activeSpeakers(in: hypothesis, startMs: region.startMs, endMs: region.endMs).isEmpty {
                coveredMs += durationMs
            }
        }

        guard totalReferenceMs > 0 else { return 0 }
        return Double(coveredMs) / Double(totalReferenceMs)
    }

    public static func speakerCountDelta(expected: Int, detected: Int) -> Int {
        detected - expected
    }

    public static func speakerCountDelta(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment]
    ) -> Int {
        speakerCountDelta(
            expected: speakerCount(reference),
            detected: speakerCount(hypothesis)
        )
    }

    public static func speakerCount(_ segments: [LabeledSegment]) -> Int {
        Set(normalized(segments).map(\.speakerId)).count
    }

    public static func speechDuration(_ segments: [LabeledSegment]) -> Int {
        mergedIntervals(normalized(segments)).reduce(0) { total, interval in
            total + interval.endMs - interval.startMs
        }
    }

    public static func speechDuration(_ segments: [SpeakerSegment]) -> Int {
        speechDuration(segments.map(LabeledSegment.init))
    }

    // JER is intentionally omitted for this baseline because a correct
    // implementation needs per-speaker union/intersection scoring under the
    // same overlap policy as DER, and DER+coverage are enough for slice 1.

    private static func derValue(
        missedMs: Int,
        falseAlarmMs: Int,
        confusionMs: Int,
        totalReferenceMs: Int
    ) -> Double {
        guard totalReferenceMs > 0 else { return 0 }
        return Double(missedMs + falseAlarmMs + confusionMs) / Double(totalReferenceMs)
    }

    private static func greedySpeakerMapping(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        regions: [Interval]
    ) -> [String: String] {
        var overlaps: [SpeakerPair: Int] = [:]

        for region in regions {
            let durationMs = region.endMs - region.startMs
            let activeReference = activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs)
            let activeHypothesis = activeSpeakers(in: hypothesis, startMs: region.startMs, endMs: region.endMs)
            for referenceSpeaker in activeReference {
                for hypothesisSpeaker in activeHypothesis {
                    overlaps[SpeakerPair(reference: referenceSpeaker, hypothesis: hypothesisSpeaker), default: 0] += durationMs
                }
            }
        }

        let pairs = overlaps.map { pair, overlap in
            (pair: pair, overlap: overlap)
        }.sorted { lhs, rhs in
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            if lhs.pair.reference != rhs.pair.reference {
                return lhs.pair.reference < rhs.pair.reference
            }
            return lhs.pair.hypothesis < rhs.pair.hypothesis
        }

        var usedReferences = Set<String>()
        var usedHypotheses = Set<String>()
        var mapping: [String: String] = [:]

        for entry in pairs {
            guard !usedReferences.contains(entry.pair.reference),
                  !usedHypotheses.contains(entry.pair.hypothesis)
            else {
                continue
            }
            usedReferences.insert(entry.pair.reference)
            usedHypotheses.insert(entry.pair.hypothesis)
            mapping[entry.pair.hypothesis] = entry.pair.reference
        }

        return mapping
    }

    private static func normalized(_ segments: [LabeledSegment]) -> [LabeledSegment] {
        segments
            .filter { !$0.speakerId.isEmpty && $0.endMs > $0.startMs }
            .sorted {
                if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
                if $0.endMs != $1.endMs { return $0.endMs < $1.endMs }
                return $0.speakerId < $1.speakerId
            }
    }

    private static func scoredRegions(
        reference: [LabeledSegment],
        hypothesis: [LabeledSegment],
        options: DiarizationScoringOptions
    ) -> [Interval] {
        var boundaries = Set((reference + hypothesis).flatMap { [$0.startMs, $0.endMs] })
        let collarIntervals = collarIntervals(reference: reference, collarMs: options.collarMs)
        for interval in collarIntervals {
            boundaries.insert(interval.startMs)
            boundaries.insert(interval.endMs)
        }

        let sorted = boundaries.sorted()
        guard sorted.count >= 2 else { return [] }

        var regions: [Interval] = []
        for index in 0..<(sorted.count - 1) {
            let region = Interval(startMs: sorted[index], endMs: sorted[index + 1])
            guard region.endMs > region.startMs else { continue }
            if collarIntervals.contains(where: { overlapDuration(region, $0) > 0 }) {
                continue
            }
            if options.skipOverlap,
               activeSpeakers(in: reference, startMs: region.startMs, endMs: region.endMs).count > 1 {
                continue
            }
            regions.append(region)
        }
        return regions
    }

    private static func collarIntervals(reference: [LabeledSegment], collarMs: Int) -> [Interval] {
        guard collarMs > 0 else { return [] }
        let beforeMs = collarMs / 2
        let afterMs = collarMs - beforeMs

        return reference.flatMap { segment in
            [
                Interval(startMs: max(0, segment.startMs - beforeMs), endMs: segment.startMs + afterMs),
                Interval(startMs: max(0, segment.endMs - beforeMs), endMs: segment.endMs + afterMs),
            ]
        }
        .filter { $0.endMs > $0.startMs }
    }

    private static func activeSpeakers(
        in segments: [LabeledSegment],
        startMs: Int,
        endMs: Int
    ) -> Set<String> {
        Set(segments.compactMap { segment in
            segment.startMs < endMs && segment.endMs > startMs ? segment.speakerId : nil
        })
    }

    private static func overlapDuration(_ lhs: Interval, _ rhs: Interval) -> Int {
        max(0, min(lhs.endMs, rhs.endMs) - max(lhs.startMs, rhs.startMs))
    }

    private static func mergedIntervals(_ segments: [LabeledSegment]) -> [Interval] {
        let intervals = segments.map { Interval(startMs: $0.startMs, endMs: $0.endMs) }
            .sorted {
                if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
                return $0.endMs < $1.endMs
            }

        var merged: [Interval] = []
        for interval in intervals where interval.endMs > interval.startMs {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }

            if interval.startMs <= last.endMs {
                merged[merged.count - 1] = Interval(
                    startMs: last.startMs,
                    endMs: max(last.endMs, interval.endMs)
                )
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
