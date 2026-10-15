import XCTest
@testable import DensosoDomain

final class StrengthTrainingTests: XCTestCase {
    func testRestTimerFinishesAtDeadline() {
        let start = Date(timeIntervalSince1970: 1_000)
        var timer = RestTimer()
        timer.start(duration: 60, now: start)

        XCTAssertEqual(timer.secondsRemaining(now: start.addingTimeInterval(10)), 50)
        XCTAssertFalse(timer.refresh(now: start.addingTimeInterval(59)))
        XCTAssertTrue(timer.refresh(now: start.addingTimeInterval(60)))
        XCTAssertEqual(timer.state, .finished)
    }

    func testStrengthSummaryUsesFinalHealthKitUUID() {
        let workoutID = UUID()
        let summary = StrengthWorkoutSummary(
            healthKitUUID: workoutID,
            logicalSessionID: UUID(),
            catalogVersion: "free-exercise-db-1",
            completedSets: [
                StrengthSetLog(
                    exerciseID: "free-exercise-db:Barbell_Squat",
                    exerciseName: "Barbell Squat",
                    repetitions: 5,
                    loadKilograms: 80
                )
            ]
        )

        XCTAssertEqual(summary.healthKitUUID, workoutID)
        XCTAssertEqual(summary.completedSets.first?.repetitions, 5)
    }
}
