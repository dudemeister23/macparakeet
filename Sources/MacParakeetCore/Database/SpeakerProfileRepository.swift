import Foundation
import GRDB

public protocol SpeakerProfileRepositoryProtocol: Sendable {
    func save(_ profile: SpeakerProfile) throws
    func fetch(id: UUID) throws -> SpeakerProfile?
    func fetchAll() throws -> [SpeakerProfile]
    func delete(id: UUID) throws -> Bool
    func deleteAll() throws
}

/// GRDB repository for enrolled speaker voice profiles. One row per known
/// speaker; the embedding column holds the JSON-encoded 256-d vector.
public final class SpeakerProfileRepository: SpeakerProfileRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ profile: SpeakerProfile) throws {
        try dbQueue.write { db in
            try profile.save(db)
        }
    }

    public func fetch(id: UUID) throws -> SpeakerProfile? {
        try dbQueue.read { db in
            try SpeakerProfile.fetchOne(db, key: id)
        }
    }

    public func fetchAll() throws -> [SpeakerProfile] {
        try dbQueue.read { db in
            try SpeakerProfile
                .order(Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try SpeakerProfile.deleteOne(db, key: id)
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in
            _ = try SpeakerProfile.deleteAll(db)
        }
    }
}
