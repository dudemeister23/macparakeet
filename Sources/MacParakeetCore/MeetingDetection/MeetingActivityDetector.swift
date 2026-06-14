import Foundation

public enum MeetingActivityDetector {
    public struct Config: Sendable, Equatable {
        public var mode: MeetingActivityDetectionMode
        public var candidateDwellSeconds: TimeInterval
        public var declineCooldownSeconds: TimeInterval

        public init(
            mode: MeetingActivityDetectionMode = .off,
            candidateDwellSeconds: TimeInterval = 3.0,
            declineCooldownSeconds: TimeInterval = 30 * 60
        ) {
            self.mode = mode
            self.candidateDwellSeconds = candidateDwellSeconds
            self.declineCooldownSeconds = declineCooldownSeconds
        }

        public static let `default` = Config()
    }

    public enum DetectionEvent: Sendable, Equatable {
        case promptToRecord(MeetingIdentity)
        case autoStartDue(MeetingIdentity)
        case signalCleared
    }

    public static func evaluate(
        signal: ActivitySignalSnapshot,
        now: Date,
        config: Config,
        activeRecording: Bool,
        candidateSince: Date?,
        suppressedIdentities: [MeetingIdentity: Date]
    ) -> [DetectionEvent] {
        guard config.mode != .off, !activeRecording else { return [] }

        guard let identity = candidateIdentity(for: signal) else {
            return candidateSince == nil ? [] : [.signalCleared]
        }

        if let suppressedUntil = suppressedIdentities[identity], suppressedUntil > now {
            return []
        }

        let stableSince = candidateSince ?? now
        guard now.timeIntervalSince(stableSince) >= config.candidateDwellSeconds else {
            return []
        }

        switch config.mode {
        case .off:
            return []
        case .prompt:
            return [.promptToRecord(identity)]
        case .autoStart:
            return [.autoStartDue(identity)]
        }
    }

    public static func candidateIdentity(for signal: ActivitySignalSnapshot) -> MeetingIdentity? {
        guard !signal.audio.inputHolders.isEmpty else { return nil }

        if let app = recognizedMeetingApp(for: signal) {
            return MeetingIdentity(source: .app, app: app)
        }

        if signal.cameraRunning {
            return MeetingIdentity(source: .camera, app: nil)
        }

        return nil
    }

    private static func recognizedMeetingApp(for signal: ActivitySignalSnapshot) -> MeetingApp? {
        let inputHolders = signal.audio.inputHolders
        let outputPIDs = Set(signal.audio.outputHolders.map(\.pid))

        let dedicated = inputHolders.compactMap { process -> MeetingApp? in
            guard let bundleID = process.bundleID,
                  let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                  descriptor.trustTier == .dedicated
            else {
                return nil
            }
            return descriptor.app
        }
        if let first = dedicated.first {
            return first
        }

        let chat = inputHolders.compactMap { process -> MeetingApp? in
            guard outputPIDs.contains(process.pid),
                  let bundleID = process.bundleID,
                  let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                  descriptor.trustTier == .chat
            else {
                return nil
            }
            return descriptor.app
        }
        if let first = chat.first {
            return first
        }

        let browser = inputHolders.compactMap { process -> MeetingApp? in
            guard let bundleID = process.bundleID,
                  let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                  descriptor.trustTier == .browser
            else {
                return nil
            }
            let isFrontmost = signal.frontmostBundleID == bundleID
            return (isFrontmost || signal.hasRecognizedMeetingURL) ? descriptor.app : nil
        }
        return browser.first
    }
}
