import XCTest
import DensosoDomain
@testable import Densoso

final class WorkoutPlanCompilerTests: XCTestCase {
    func testWorkoutKitErrorsUseSharedCodesAndSafeMessages() {
        let authorizationError = WorkoutPlanCompileError.scheduleAuthorizationDenied
        XCTAssertEqual(authorizationError.sharedErrorDescriptor.code, .workoutKitUnauthorized)
        XCTAssertEqual(authorizationError.localizedDescription, authorizationError.sharedErrorDescriptor.userMessage)

        let unsupportedError = WorkoutPlanCompileError.schedulingUnavailable
        XCTAssertEqual(unsupportedError.sharedErrorDescriptor.code, .watchUnavailable)

        let invalidPlan = TrainingPlanCompileError.invalidDraft(.invalidReason)
        XCTAssertEqual(invalidPlan.sharedErrorDescriptor.code, .toolArgumentsInvalid)
        XCTAssertEqual(invalidPlan.localizedDescription, invalidPlan.sharedErrorDescriptor.userMessage)
    }

    func testSupportedSingleGoalDraftValidatesWithoutStrengthSetData() throws {
        let draft = WorkoutPlanDraft(
            name: "晚间步行",
            activity: .walking,
            location: .outdoor,
            goal: .timeMinutes(30),
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(draft.strengthSets.isEmpty)
        XCTAssertNoThrow(try WorkoutPlanCompiler().validate(draft))
    }

    func testDistanceGoalRangeAndScheduledTimeAreValidated() throws {
        let valid = WorkoutPlanDraft(
            name: "五公里跑",
            activity: .running,
            goal: .distanceMeters(5_000),
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNoThrow(try WorkoutPlanCompiler().validate(valid))

        let tooShort = WorkoutPlanDraft(
            name: "过短",
            activity: .running,
            goal: .distanceMeters(50),
            scheduledAt: valid.scheduledAt
        )
        XCTAssertThrowsError(try WorkoutPlanCompiler().validate(tooShort)) {
            XCTAssertEqual($0 as? WorkoutPlanCompileError, .invalidDistanceGoal)
        }

        let unscheduled = WorkoutPlanDraft(name: "没有时间", activity: .walking)
        XCTAssertThrowsError(try WorkoutPlanCompiler().validate(unscheduled)) {
            XCTAssertEqual($0 as? WorkoutPlanCompileError, .scheduleDateRequired)
        }
    }

    func testLegacyStrengthPlanIsRejectedAndNotCompiledAsAWorkout() {
        let legacy = WorkoutPlanDraft(
            name: "旧版组次计划",
            activity: .strength,
            goal: .timeMinutes(45),
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            strengthSets: [.init(exerciseName: "深蹲", setCount: 5, repetitions: 5)]
        )
        XCTAssertThrowsError(try WorkoutPlanCompiler().validate(legacy)) {
            XCTAssertEqual($0 as? WorkoutPlanCompileError, .unsupportedActivity)
        }
    }

    func testStrengthSetsAreRejectedEvenForAWorkoutKitSupportedActivity() {
        let legacyFields = WorkoutPlanDraft(
            name: "带有旧组次字段的步行",
            activity: .walking,
            goal: .open,
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000),
            strengthSets: [.init(exerciseName: "深蹲", setCount: 5, repetitions: 5)]
        )
        XCTAssertThrowsError(try WorkoutPlanCompiler().validate(legacyFields)) {
            XCTAssertEqual($0 as? WorkoutPlanCompileError, .invalidLegacyStrengthData)
        }
    }
}
