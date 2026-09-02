import XCTest
@testable import DensosoDomain

final class WatchWorkoutCoordinatorTests: XCTestCase {
    func testLifecyclePreservesLogicalSessionAcrossPauseAndResume() async throws {
        let logicalSession = LogicalWorkoutSession(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, startedAt: .distantPast)
        let coordinator = WatchWorkoutCoordinator(logicalSession: logicalSession)

        _ = try await coordinator.send(.prepare)
        _ = try await coordinator.send(.start)
        _ = try await coordinator.send(.pause)
        let resumed = try await coordinator.send(.resume)

        XCTAssertEqual(resumed.state, .running)
        XCTAssertEqual(resumed.logicalSession, logicalSession)
    }

    func testInvalidTransitionDoesNotAdvanceState() async throws {
        let coordinator = WatchWorkoutCoordinator()

        do {
            _ = try await coordinator.send(.start)
            XCTFail("Starting without preparation must fail")
        } catch let error as WorkoutSessionTransitionError {
            XCTAssertEqual(error, .invalidTransition(state: .idle, event: .start))
        }

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.state, .idle)
    }

    func testDiscardCreatesANewLogicalSessionForTheNextWorkout() async throws {
        let coordinator = WatchWorkoutCoordinator()
        let initial = await coordinator.snapshot()

        _ = try await coordinator.send(.prepare)
        _ = try await coordinator.send(.discard)
        let preparedAgain = try await coordinator.send(.prepare)

        XCTAssertEqual(preparedAgain.state, .prepared)
        XCTAssertNotEqual(preparedAgain.logicalSession.id, initial.logicalSession.id)
    }

    func testEndCreatesANewLogicalSessionForTheNextWorkout() async throws {
        let coordinator = WatchWorkoutCoordinator()
        let initial = await coordinator.snapshot()

        _ = try await coordinator.send(.prepare)
        _ = try await coordinator.send(.start)
        _ = try await coordinator.send(.end)
        let preparedAgain = try await coordinator.send(.prepare)

        XCTAssertEqual(preparedAgain.state, .prepared)
        XCTAssertNotEqual(preparedAgain.logicalSession.id, initial.logicalSession.id)
    }
}
