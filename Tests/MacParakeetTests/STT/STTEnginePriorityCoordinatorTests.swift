import XCTest

@testable import MacParakeetCore

private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
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

    // MARK: - Preemption

    func testRegisteredPreemptionFiresWhenDictationActivates() {
        let coordinator = STTEnginePriorityCoordinator()
        let counter = Counter()
        let token = coordinator.registerPreemption { counter.increment() }
        XCTAssertEqual(counter.value, 0, "should not fire while dictation is idle")

        coordinator.setDictationActive(true)
        XCTAssertEqual(counter.value, 1, "an in-flight span must be preempted the instant dictation activates")

        coordinator.unregisterPreemption(token)
    }

    func testRegisterWhileActiveFiresImmediately() {
        let coordinator = STTEnginePriorityCoordinator()
        coordinator.setDictationActive(true)

        let counter = Counter()
        _ = coordinator.registerPreemption { counter.increment() }
        XCTAssertEqual(counter.value, 1, "a span started in the gap after the idle gate must still be preempted")
    }

    func testUnregisteredPreemptionDoesNotFire() {
        let coordinator = STTEnginePriorityCoordinator()
        let counter = Counter()
        let token = coordinator.registerPreemption { counter.increment() }
        coordinator.unregisterPreemption(token)

        coordinator.setDictationActive(true)
        XCTAssertEqual(counter.value, 0, "a settled span's handler must not fire")
    }

    func testDeactivationDoesNotPreempt() {
        let coordinator = STTEnginePriorityCoordinator()
        let counter = Counter()
        _ = coordinator.registerPreemption { counter.increment() }

        coordinator.setDictationActive(true)
        coordinator.setDictationActive(false)
        XCTAssertEqual(counter.value, 1, "going idle must not re-fire preemption")
    }
}
