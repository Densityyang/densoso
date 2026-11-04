import XCTest
import DensosoDomain
@testable import Densoso

@MainActor
final class DailyHealthSampleSummaryBuilderTests: XCTestCase {
    func testWorkoutEffortSampleIsAssignedToOnlyOneOverlappingWorkout() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let firstWorkout = WorkoutRecord(
            date: start,
            type: "running",
            durationMinutes: 60,
            intensity: "unknown",
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000811")!,
            workoutOrigin: "externalHealthKit"
        )
        let secondWorkout = WorkoutRecord(
            date: start.addingTimeInterval(30 * 60),
            type: "running",
            durationMinutes: 60,
            intensity: "unknown",
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000812")!,
            workoutOrigin: "externalHealthKit"
        )
        let effort = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000813")!,
            metric: .workoutEffort,
            startDate: start.addingTimeInterval(45 * 60),
            endDate: start.addingTimeInterval(75 * 60),
            value: 7
        )

        let forward = DailyHealthSampleSummaryBuilder.build(
            samples: [effort],
            dayStart: start,
            workouts: [firstWorkout, secondWorkout]
        )
        let reversed = DailyHealthSampleSummaryBuilder.build(
            samples: [effort],
            dayStart: start,
            workouts: [secondWorkout, firstWorkout]
        )

        XCTAssertEqual(forward.workoutEffort.count, 1)
        XCTAssertEqual(forward.workoutEffort.first?.workoutRecordID, secondWorkout.id)
        XCTAssertEqual(forward.workoutEffort.first?.score, 7)
        XCTAssertEqual(reversed.workoutEffort, forward.workoutEffort)
    }

    func testWorkoutEffortAssignmentIgnoresInvalidScoresAndDuplicateSamples() {
        let start = Date(timeIntervalSince1970: 1_800_000_100)
        let workout = WorkoutRecord(
            date: start,
            type: "cycling",
            durationMinutes: 45,
            intensity: "unknown",
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000814")!,
            workoutOrigin: "externalHealthKit"
        )
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000815")!
        let sample = HealthSampleSnapshot(
            id: sampleID,
            metric: .workoutEffort,
            startDate: start.addingTimeInterval(5 * 60),
            endDate: start.addingTimeInterval(40 * 60),
            value: 6
        )
        let invalidScore = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000816")!,
            metric: .workoutEffort,
            startDate: start,
            endDate: start.addingTimeInterval(45 * 60),
            value: 11
        )

        let summary = DailyHealthSampleSummaryBuilder.build(
            samples: [sample, sample, invalidScore],
            dayStart: start,
            workouts: [workout]
        )

        XCTAssertEqual(summary.workoutEffort, [WorkoutEffortDailyAggregate(workoutRecordID: workout.id, score: 6)])
    }

    func testDistinctEffortSamplesMatchDistinctOverlappingWorkouts() {
        let start = Date(timeIntervalSince1970: 1_800_000_200)
        let firstWorkout = WorkoutRecord(
            date: start,
            type: "running",
            durationMinutes: 90,
            intensity: "unknown",
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000817")!,
            workoutOrigin: "externalHealthKit"
        )
        let secondWorkout = WorkoutRecord(
            date: start.addingTimeInterval(30 * 60),
            type: "running",
            durationMinutes: 60,
            intensity: "unknown",
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000818")!,
            workoutOrigin: "externalHealthKit"
        )
        let firstEffort = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000819")!,
            metric: .workoutEffort,
            startDate: start.addingTimeInterval(35 * 60),
            endDate: start.addingTimeInterval(45 * 60),
            value: 5
        )
        let secondEffort = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000820")!,
            metric: .workoutEffort,
            startDate: start.addingTimeInterval(40 * 60),
            endDate: start.addingTimeInterval(50 * 60),
            value: 8
        )

        let summary = DailyHealthSampleSummaryBuilder.build(
            samples: [secondEffort, firstEffort],
            dayStart: start,
            workouts: [secondWorkout, firstWorkout]
        )

        XCTAssertEqual(summary.workoutEffort.count, 2)
        XCTAssertEqual(summary.effortScore(for: firstWorkout.id), 5)
        XCTAssertEqual(summary.effortScore(for: secondWorkout.id), 8)
    }
}
