import Foundation
import MacParakeetCore

@MainActor
final class AppStartupBootstrapper {
    func bootstrapEnvironment() async throws -> AppEnvironment {
        let bootstrapTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try AppPaths.ensureDirectories()
            try Task.checkCancellation()

            let manager = try DatabaseManager(path: AppPaths.databasePath)
            try Task.checkCancellation()
            return manager
        }

        let databaseManager = try await withTaskCancellationHandler {
            try await bootstrapTask.value
        } onCancel: {
            bootstrapTask.cancel()
        }

        try Task.checkCancellation()
        let environment = try AppEnvironment(databaseManager: databaseManager)
        scheduleLaunchCleanup(databaseManager: databaseManager)
        return environment
    }

    /// One-time launch cleanup, deliberately fire-and-forget: it used to run
    /// inside the awaited bootstrap task, where per-row `fileExists` checks
    /// over a large dictation history delayed app readiness. Nothing
    /// downstream consumes its result (failures were already swallowed); the
    /// only visible effect of deferring it is that a dictation whose audio
    /// file was deleted externally may briefly keep its stale path until the
    /// sweep lands.
    private nonisolated func scheduleLaunchCleanup(databaseManager: DatabaseManager) {
        let dbQueue = databaseManager.dbQueue
        Task.detached(priority: .utility) {
            let dictationRepo = DictationRepository(dbQueue: dbQueue)
            _ = try? dictationRepo.deleteEmpty()
            try? dictationRepo.clearMissingAudioPaths()
        }
    }
}
