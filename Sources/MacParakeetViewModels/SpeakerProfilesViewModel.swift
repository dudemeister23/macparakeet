import Foundation
import MacParakeetCore

/// Drives the speaker-profile management UI: list enrolled speakers, enroll a
/// new one by recording a short mic sample, rename, and delete. Recording uses
/// `SpeakerEnrollmentRecorder` (shared mic) and embedding uses
/// `SpeakerEmbeddingService` — the same path meeting recognition matches against.
@MainActor
@Observable
public final class SpeakerProfilesViewModel {
    public enum EnrollmentPhase: Equatable {
        case idle
        case recording
        case processing
    }

    public private(set) var profiles: [SpeakerProfile] = []
    public var errorMessage: String?

    // Enrollment
    public var enrollmentName: String = ""
    public private(set) var phase: EnrollmentPhase = .idle
    public private(set) var recordedSeconds: Double = 0

    // Inline rename
    public var editingProfileID: UUID?
    public var editName: String = ""

    /// Minimum speech before enrollment can be saved; below this the embedding is
    /// unreliable. ~20s is a comfortable target.
    public let minSeconds: Double = 5
    public let targetSeconds: Double = 20

    private var repo: SpeakerProfileRepositoryProtocol?
    private var embedder: SpeakerEmbeddingServiceProtocol?
    private var recorder: SpeakerEnrollmentRecorder?
    private var progressTask: Task<Void, Never>?

    public init() {}

    public func configure(
        repo: SpeakerProfileRepositoryProtocol,
        embedder: SpeakerEmbeddingServiceProtocol,
        recorder: SpeakerEnrollmentRecorder
    ) {
        self.repo = repo
        self.embedder = embedder
        self.recorder = recorder
        load()
    }

    public func load() {
        guard let repo else { return }
        do {
            profiles = try repo.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public var trimmedEnrollmentName: String {
        enrollmentName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canStartEnrollment: Bool {
        phase == .idle && !trimmedEnrollmentName.isEmpty
    }

    public var canSaveEnrollment: Bool {
        phase == .recording && recordedSeconds >= minSeconds
    }

    public func startEnrollment() {
        guard let recorder, canStartEnrollment else { return }
        errorMessage = nil
        recordedSeconds = 0
        phase = .recording
        progressTask = Task { @MainActor [weak self, recorder] in
            do {
                try await recorder.start()
            } catch {
                self?.failEnrollment(error)
                return
            }
            while !Task.isCancelled {
                guard let self, self.phase == .recording else { return }
                self.recordedSeconds = await recorder.capturedSeconds
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    public func saveEnrollment() async {
        guard let recorder, let embedder, let repo, phase == .recording else { return }
        progressTask?.cancel()
        phase = .processing
        let samples = await recorder.stop()
        guard Double(samples.count) >= minSeconds * 16_000 else {
            errorMessage = "Need at least \(Int(minSeconds))s of speech — try again."
            phase = .idle
            return
        }
        do {
            let embedding = try await embedder.embed(samples: samples)
            let profile = SpeakerProfile(
                name: trimmedEnrollmentName,
                embedding: embedding,
                enrolledSeconds: Double(samples.count) / 16_000
            )
            try repo.save(profile)
            enrollmentName = ""
            recordedSeconds = 0
            phase = .idle
            load()
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    public func cancelEnrollment() async {
        progressTask?.cancel()
        if let recorder { _ = await recorder.stop() }
        recordedSeconds = 0
        phase = .idle
    }

    private func failEnrollment(_ error: Error) {
        errorMessage = "Couldn't start recording: \(error.localizedDescription)"
        phase = .idle
        recordedSeconds = 0
    }

    // MARK: - Rename / delete

    public func beginRename(_ profile: SpeakerProfile) {
        editingProfileID = profile.id
        editName = profile.name
    }

    public func commitRename() {
        guard let id = editingProfileID,
              let repo,
              var profile = profiles.first(where: { $0.id == id })
        else { return }
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingProfileID = nil
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        profile.name = trimmed
        profile.updatedAt = Date()
        do {
            try repo.save(profile)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelRename() {
        editingProfileID = nil
    }

    public func delete(_ profile: SpeakerProfile) {
        guard let repo else { return }
        do {
            _ = try repo.delete(id: profile.id)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
