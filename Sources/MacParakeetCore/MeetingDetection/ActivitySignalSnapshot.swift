import Foundation

public struct AudioProcessActivity: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(
        pid: Int32,
        bundleID: String?,
        isRunningInput: Bool,
        isRunningOutput: Bool
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

public struct ProcessAudioSnapshot: Sendable, Equatable {
    public let processes: [AudioProcessActivity]

    public init(processes: [AudioProcessActivity]) {
        self.processes = processes
    }

    public var inputHolders: [AudioProcessActivity] {
        processes.filter(\.isRunningInput)
    }

    public var outputHolders: [AudioProcessActivity] {
        processes.filter(\.isRunningOutput)
    }
}

public struct ActivitySignalSnapshot: Sendable, Equatable {
    public let audio: ProcessAudioSnapshot
    public let cameraRunning: Bool
    public let frontmostBundleID: String?
    public let hasRecognizedMeetingURL: Bool

    public init(
        audio: ProcessAudioSnapshot,
        cameraRunning: Bool = false,
        frontmostBundleID: String? = nil,
        hasRecognizedMeetingURL: Bool = false
    ) {
        self.audio = audio
        self.cameraRunning = cameraRunning
        self.frontmostBundleID = frontmostBundleID
        self.hasRecognizedMeetingURL = hasRecognizedMeetingURL
    }
}

public struct MeetingIdentity: Sendable, Hashable {
    public enum Source: String, Sendable {
        case app
        case camera
    }

    public let source: Source
    public let app: MeetingApp?

    public init(source: Source, app: MeetingApp?) {
        self.source = source
        self.app = app
    }
}
