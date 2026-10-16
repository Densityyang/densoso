import Foundation
import XCTest
@testable import DensosoDomain

final class TrainingPlanDraftTests: XCTestCase {
    func testMultiDayPlanAcceptsWorkoutAndRestDays() {
        let plan = TrainingPlanDraft(
            name: "轻松恢复",
            sessions: [
                TrainingSessionDraft(
                    date: Date(timeIntervalSince1970: 1_800_000_000),
                    activity: .walking,
                    goal: .timeMinutes(30),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "以轻松步行保持日常活动。"
                ),
                TrainingSessionDraft(
                    date: Date(timeIntervalSince1970: 1_800_086_400),
                    activity: nil,
                    reason: "安排休息，让身体恢复。"
                ),
            ]
        )

        XCTAssertNil(plan.validationError)
        XCTAssertFalse(plan.sessions[0].isRestDay)
        XCTAssertTrue(plan.sessions[1].isRestDay)
    }

    func testRestDayCannotCarryWorkoutInstructions() {
        let session = TrainingSessionDraft(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            activity: nil,
            goal: .timeMinutes(30),
            reason: "安排休息。"
        )

        XCTAssertEqual(session.validationError, .invalidRestSession)
    }

    func testCanonicalMultiDayPlanIgnoresSessionOrderAndGeneratedIdentifiers() throws {
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)
        let secondDate = firstDate.addingTimeInterval(86_400)
        let first = TrainingSessionDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            date: firstDate,
            activity: .walking,
            goal: .timeMinutes(30),
            location: .outdoor,
            recommendedIntensity: .easy,
            reason: "轻松活动。"
        )
        let rest = TrainingSessionDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            date: secondDate,
            activity: nil,
            reason: "恢复。"
        )
        let reorderedWithNewIDs = [
            TrainingSessionDraft(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                date: secondDate,
                activity: nil,
                reason: "恢复。"
            ),
            TrainingSessionDraft(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                date: firstDate,
                activity: .walking,
                goal: .timeMinutes(30),
                location: .outdoor,
                recommendedIntensity: .easy,
                reason: "轻松活动。"
            ),
        ]
        let lhs = TrainingPlanDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            name: "轻松计划",
            createdAt: Date(timeIntervalSince1970: 1_799_000_000),
            sessions: [first, rest]
        )
        let rhs = TrainingPlanDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            name: "轻松计划",
            createdAt: Date(timeIntervalSince1970: 1_799_500_000),
            sessions: reorderedWithNewIDs
        )

        XCTAssertEqual(
            try ActionPayload.trainingPlan(lhs).canonicalData(),
            try ActionPayload.trainingPlan(rhs).canonicalData()
        )
    }
}
