import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class DailyMetricsProjectionWriteGateTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: UserProfile.self, DailyMetrics.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    func testChildTaskCannotInheritParentGateOwnership() async throws {
        let parentReady = GateTestSignal()
        let releaseParent = GateTestSignal()
        var childEntered = false
        var childTask: Task<Void, Error>?

        let parentTask = Task {
            try await DailyMetricsProjectionWriteGate.withLock(for: context) {
                childTask = Task {
                    try await DailyMetricsProjectionWriteGate.withLock(for: context) {
                        childEntered = true
                    }
                }
                await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(
                    1,
                    storeID: ObjectIdentifier(container)
                )
                parentReady.signal()
                await releaseParent.wait()
            }
        }

        await parentReady.wait()
        XCTAssertFalse(childEntered)
        releaseParent.signal()
        try await parentTask.value
        guard let childTask else { return XCTFail("Parent task did not create its child") }
        try await childTask.value
        XCTAssertTrue(childEntered)
    }

    func testCancelledGateWaiterIsRemovedBeforeNextWaiterAcquires() async throws {
        let owner = try await DailyMetricsProjectionWriteGate.acquire(storeID: ObjectIdentifier(container))
        var cancelledWaiterEntered = false
        var laterWaiterEntered = false

        let cancelledWaiter = Task {
            do {
                try await DailyMetricsProjectionWriteGate.withLock(for: context) {
                    cancelledWaiterEntered = true
                }
                return true
            } catch is CancellationError {
                return false
            }
        }
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(1, storeID: ObjectIdentifier(container))

        let laterWaiter = Task {
            try await DailyMetricsProjectionWriteGate.withLock(for: context) {
                laterWaiterEntered = true
            }
        }
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(2, storeID: ObjectIdentifier(container))

        cancelledWaiter.cancel()
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(1, storeID: ObjectIdentifier(container))
        DailyMetricsProjectionWriteGate.release(owner)

        let cancelledWaiterAcquired = try await cancelledWaiter.value
        XCTAssertFalse(cancelledWaiterAcquired)
        try await laterWaiter.value
        XCTAssertFalse(cancelledWaiterEntered)
        XCTAssertTrue(laterWaiterEntered)
    }

    func testIndependentContextsForSameStoreShareTheProjectionGate() async throws {
        let secondContext = ModelContext(container)
        let owner = try await DailyMetricsProjectionWriteGate.acquire(storeID: ObjectIdentifier(container))
        var secondContextEntered = false
        let secondContextTask = Task {
            try await DailyMetricsProjectionWriteGate.withLock(for: secondContext) {
                secondContextEntered = true
            }
        }

        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(1, storeID: ObjectIdentifier(container))
        XCTAssertFalse(secondContextEntered)
        DailyMetricsProjectionWriteGate.release(owner)
        try await secondContextTask.value
        XCTAssertTrue(secondContextEntered)
    }

    func testDifferentLogicalDaysCanProceedConcurrentlyOnSameStore() async throws {
        let storeID = ObjectIdentifier(container)
        let dayA = "2026-11-03"
        let dayB = "2026-11-04"
        let owner = try await DailyMetricsProjectionWriteGate.acquire(storeID: storeID, dayKeys: [dayA])
        var sameDayEntered = false
        var otherDayEntered = false
        let sameDayTask = Task {
            try await DailyMetricsProjectionWriteGate.withLock(for: context, dayKeys: [dayA]) {
                sameDayEntered = true
            }
        }
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(1, storeID: storeID)

        let otherDayTask = Task {
            try await DailyMetricsProjectionWriteGate.withLock(for: context, dayKeys: [dayB]) {
                otherDayEntered = true
            }
        }
        try await otherDayTask.value
        XCTAssertTrue(otherDayEntered)
        XCTAssertFalse(sameDayEntered)

        DailyMetricsProjectionWriteGate.release(owner)
        try await sameDayTask.value
        XCTAssertTrue(sameDayEntered)
    }
}

@MainActor
private final class GateTestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
