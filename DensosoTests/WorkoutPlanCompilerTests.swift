import XCTest
@testable import Densoso

final class WorkoutPlanCompilerTests: XCTestCase {
    func testFiveByFiveDraftIsValidBeforeSystemConfirmation() throws {
        let draft = WorkoutPlanDraft.squatFiveByFive

        XCTAssertNoThrow(try WorkoutPlanCompiler().validate(draft))
        XCTAssertEqual(draft.strengthSets.first?.setCount, 5)
        XCTAssertEqual(draft.strengthSets.first?.repetitions, 5)
    }

    func testInvalidStrengthSetIsRejectedLocally() {
        let draft = WorkoutPlanDraft(
            name: "坏数据",
            activity: .strength,
            strengthSets: [.init(exerciseName: "", setCount: 0, repetitions: 0)]
        )

        XCTAssertThrowsError(try WorkoutPlanCompiler().validate(draft)) { error in
            XCTAssertEqual(error as? WorkoutPlanCompileError, .invalidStrengthSet)
        }
    }

    func testInvalidTimeGoalIsRejectedLocally() {
        let draft = WorkoutPlanDraft(name: "过长", activity: .walking, goal: .timeMinutes(0))

        XCTAssertThrowsError(try WorkoutPlanCompiler().validate(draft)) { error in
            XCTAssertEqual(error as? WorkoutPlanCompileError, .invalidTimeGoal)
        }
    }
}
