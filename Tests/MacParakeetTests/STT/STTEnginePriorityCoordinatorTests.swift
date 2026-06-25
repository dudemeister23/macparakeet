import XCTest

@testable import MacParakeetCore

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

final class STTEnginePriorityCoordinatorTests: XCTestCase {
    func testIdleReturnsImmediately() async {
        let coordinator = STTEnginePriorityCoordinator()
        XCTAssertFalse(coordinator.isDictationActive)
        await coordinator.awaitDictationIdle()  // returns immediately; test completing proves it
    }

    func testBlocksWhileActiveThenResumes() async {
        let coordinator = STTEnginePriorityCoordinator()
        let flag = Flag()
        coordinator.setDictationActive(true)
        XCTAssertTrue(coordinator.isDictationActive)

        let waiter = Task {
            await coordinator.awaitDictationIdle()
            await flag.set()
        }

        try? await Task.sleep(for: .milliseconds(80))
        let resolvedWhileActive = await flag.value
        XCTAssertFalse(resolvedWhileActive, "should still be waiting while dictation is active")

        coordinator.setDictationActive(false)
        await waiter.value
        let resolvedAfterIdle = await flag.value
        XCTAssertTrue(resolvedAfterIdle, "should resume once dictation goes idle")
    }

    func testResumesAllWaiters() async {
        let coordinator = STTEnginePriorityCoordinator()
        coordinator.setDictationActive(true)
        let waiters = (0..<5).map { _ in Task { await coordinator.awaitDictationIdle() } }
        try? await Task.sleep(for: .milliseconds(30))
        coordinator.setDictationActive(false)
        for waiter in waiters {
            await waiter.value  // all resume; hang here would fail the test
        }
    }
}
