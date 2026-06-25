import GRDB
import XCTest

@testable import MacParakeetCore

final class SpeakerProfileRepositoryTests: XCTestCase {
    var repo: SpeakerProfileRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = SpeakerProfileRepository(dbQueue: manager.dbQueue)
    }

    func testSaveAndFetchPreservesEmbedding() throws {
        // 256-d embedding with distinctive values to catch JSON round-trip loss.
        let embedding = (0..<256).map { Float($0) * 0.0123 - 1.5 }
        let profile = SpeakerProfile(name: "Sara", embedding: embedding, enrolledSeconds: 22.5)
        try repo.save(profile)

        let fetched = try XCTUnwrap(try repo.fetch(id: profile.id))
        XCTAssertEqual(fetched.name, "Sara")
        XCTAssertEqual(fetched.enrolledSeconds, 22.5, accuracy: 1e-6)
        XCTAssertEqual(fetched.embedding.count, 256)
        for (a, b) in zip(fetched.embedding, embedding) {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
    }

    func testFetchAllSortedByNameCaseInsensitive() throws {
        try repo.save(SpeakerProfile(name: "zoe", embedding: [1, 0]))
        try repo.save(SpeakerProfile(name: "Alex", embedding: [0, 1]))
        try repo.save(SpeakerProfile(name: "mike", embedding: [1, 1]))

        XCTAssertEqual(try repo.fetchAll().map(\.name), ["Alex", "mike", "zoe"])
    }

    func testUpdateInPlace() throws {
        var profile = SpeakerProfile(name: "Temp", embedding: [1, 0, 0])
        try repo.save(profile)

        profile.name = "Renamed"
        profile.embedding = [0, 1, 0]
        try repo.save(profile)

        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Renamed")
        XCTAssertEqual(all.first?.embedding, [0, 1, 0])
    }

    func testDelete() throws {
        let profile = SpeakerProfile(name: "Gone", embedding: [1])
        try repo.save(profile)
        XCTAssertTrue(try repo.delete(id: profile.id))
        XCTAssertNil(try repo.fetch(id: profile.id))
        XCTAssertFalse(try repo.delete(id: profile.id))
    }
}
