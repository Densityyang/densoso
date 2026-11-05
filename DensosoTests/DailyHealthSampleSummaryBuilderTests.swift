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

    func testGlobalAssignmentFindsBothMatchesInGreedyTwoByTwoCounterexample() {
        let start = Date(timeIntervalSince1970: 1_800_001_000)
        let firstWorkout = makeWorkout(901, start: start, durationMinutes: 10)
        let secondWorkout = makeWorkout(902, start: start.addingTimeInterval(10 * 60), durationMinutes: 10)
        let broadEffort = makeEffort(911, start: start, end: start.addingTimeInterval(20 * 60), score: 5)
        let firstOnlyEffort = makeEffort(912, start: start, end: start.addingTimeInterval(10 * 60), score: 8)

        let summary = DailyHealthSampleSummaryBuilder.build(
            samples: [broadEffort, firstOnlyEffort],
            dayStart: start,
            workouts: [firstWorkout, secondWorkout]
        )

        XCTAssertEqual(summary.workoutEffort.count, 2)
        XCTAssertEqual(summary.effortScore(for: firstWorkout.id), 8)
        XCTAssertEqual(summary.effortScore(for: secondWorkout.id), 5)
    }

    func testGlobalAssignmentHandlesTwoByThreeAndThreeByTwoInputs() {
        let start = Date(timeIntervalSince1970: 1_800_002_000)
        let twoByThreeWorkouts = [
            makeWorkout(921, start: start, durationMinutes: 10),
            makeWorkout(922, start: start.addingTimeInterval(10 * 60), durationMinutes: 10),
            makeWorkout(923, start: start.addingTimeInterval(20 * 60), durationMinutes: 10),
        ]
        let twoEfforts = [
            makeEffort(931, start: start, end: start.addingTimeInterval(20 * 60), score: 5),
            makeEffort(932, start: start.addingTimeInterval(10 * 60), end: start.addingTimeInterval(30 * 60), score: 8),
        ]
        let twoByThree = DailyHealthSampleSummaryBuilder.build(
            samples: twoEfforts,
            dayStart: start,
            workouts: twoByThreeWorkouts
        )
        XCTAssertEqual(twoByThree.workoutEffort.count, 2)
        XCTAssertEqual(Set(twoByThree.workoutEffort.map(\.workoutRecordID)).count, 2)

        let threeByTwoWorkouts = Array(twoByThreeWorkouts.prefix(2))
        let threeEfforts = [
            makeEffort(941, start: start, end: start.addingTimeInterval(20 * 60), score: 3),
            makeEffort(942, start: start, end: start.addingTimeInterval(10 * 60), score: 6),
            makeEffort(943, start: start.addingTimeInterval(10 * 60), end: start.addingTimeInterval(20 * 60), score: 9),
        ]
        let threeByTwo = DailyHealthSampleSummaryBuilder.build(
            samples: threeEfforts,
            dayStart: start,
            workouts: threeByTwoWorkouts
        )
        XCTAssertEqual(threeByTwo.workoutEffort.count, 2)
        XCTAssertEqual(Set(threeByTwo.workoutEffort.map(\.workoutRecordID)).count, 2)
    }

    func testEqualWeightAssignmentUsesUUIDOrderAndIsInputOrderIndependent() {
        let start = Date(timeIntervalSince1970: 1_800_003_000)
        let firstWorkout = makeWorkout(951, start: start, durationMinutes: 10)
        let secondWorkout = makeWorkout(952, start: start, durationMinutes: 10)
        let firstEffort = makeEffort(961, start: start, end: start.addingTimeInterval(10 * 60), score: 4)
        let secondEffort = makeEffort(962, start: start, end: start.addingTimeInterval(10 * 60), score: 9)

        let forward = DailyHealthSampleSummaryBuilder.build(
            samples: [firstEffort, secondEffort],
            dayStart: start,
            workouts: [firstWorkout, secondWorkout]
        )
        let reversed = DailyHealthSampleSummaryBuilder.build(
            samples: [secondEffort, firstEffort],
            dayStart: start,
            workouts: [secondWorkout, firstWorkout]
        )

        XCTAssertEqual(forward.workoutEffort, reversed.workoutEffort)
        XCTAssertEqual(forward.effortScore(for: firstWorkout.id), 4)
        XCTAssertEqual(forward.effortScore(for: secondWorkout.id), 9)
    }

    func testNoOverlapCreatesNoEffortAssociation() {
        let start = Date(timeIntervalSince1970: 1_800_004_000)
        let workout = makeWorkout(971, start: start, durationMinutes: 10)
        let touchingEffort = makeEffort(
            972,
            start: start.addingTimeInterval(10 * 60),
            end: start.addingTimeInterval(20 * 60),
            score: 7
        )

        let summary = DailyHealthSampleSummaryBuilder.build(
            samples: [touchingEffort],
            dayStart: start,
            workouts: [workout]
        )

        XCTAssertTrue(summary.workoutEffort.isEmpty)
    }

    func testOversizedComponentLeavesOnlyItsEffortUnassociated() {
        let start = Date(timeIntervalSince1970: 1_800_005_000)
        let workout = makeWorkout(981, start: start, durationMinutes: 10)
        let independentWorkout = makeWorkout(
            982,
            start: start.addingTimeInterval(24 * 60 * 60),
            durationMinutes: 10
        )
        let efforts = (0..<129).map { offset in
            makeEffort(
                1_000 + offset,
                start: start,
                end: start.addingTimeInterval(10 * 60),
                score: Double((offset % 10) + 1)
            )
        }
        let independentEffort = makeEffort(
            1_200,
            start: independentWorkout.date,
            end: independentWorkout.date.addingTimeInterval(10 * 60),
            score: 6
        )

        let summary = DailyHealthSampleSummaryBuilder.build(
            samples: efforts + [independentEffort],
            dayStart: start,
            workouts: [workout, independentWorkout]
        )

        XCTAssertEqual(summary.workoutEffort, [
            WorkoutEffortDailyAggregate(workoutRecordID: independentWorkout.id, score: 6),
        ])
        XCTAssertNil(summary.effortScore(for: workout.id))
    }

    private func makeWorkout(_ id: Int, start: Date, durationMinutes: Int) -> WorkoutRecord {
        WorkoutRecord(
            date: start,
            type: "running",
            durationMinutes: durationMinutes,
            intensity: "unknown",
            healthKitUUID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            workoutOrigin: "externalHealthKit"
        )
    }

    private func makeEffort(_ id: Int, start: Date, end: Date, score: Double) -> HealthSampleSnapshot {
        HealthSampleSnapshot(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            metric: .workoutEffort,
            startDate: start,
            endDate: end,
            value: score
        )
    }
}
