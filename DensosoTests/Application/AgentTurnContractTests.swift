import DensosoDomain
import XCTest
@testable import Densoso

final class AgentTurnContractTests: XCTestCase {
    func testLocalRecordSuggestionRemainsAProposalInsteadOfAStagedAction() {
        let turn = AgentTurnContract.local(
            LocalIntelligenceResult(
                reply: "我识别到一个可能的餐食记录。",
                suggestion: LocalRecordSuggestion(kind: .meal, item: "米饭", amount: "一碗")
            )
        )

        XCTAssertEqual(
            turn.intents,
            [.captureProposal(LocalRecordSuggestion(kind: .meal, item: "米饭", amount: "一碗"))]
        )
        XCTAssertTrue(turn.stagedActionIDs.isEmpty)
        XCTAssertEqual(turn.text, "我识别到一个可能的餐食记录。")
    }

    func testCloudConfirmationActionsUseTheSameTypedTurnContract() {
        let draft = WeightDraft(measuredAt: Date(timeIntervalSince1970: 1), kilograms: 62)
        let action = PendingAction(
            id: UUID(),
            idempotencyKey: "fixture",
            clientRequestID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 100),
            payload: .weight(draft),
            state: .pending
        )

        let turn = AgentTurnContract.cloud(reply: "体重草稿已待确认。", stagedActions: [action])

        XCTAssertEqual(turn.intents, [.recordWeight(draft)])
        XCTAssertEqual(turn.stagedActionIDs, [action.id])
        XCTAssertEqual(turn.text, "体重草稿已待确认。")
    }

    func testTurnsWithoutActionsUseTheAnswerIntent() {
        XCTAssertEqual(
            AgentTurnContract.cloud(reply: "今天的记录还不完整。", stagedActions: []).intents,
            [.answer("今天的记录还不完整。")]
        )
        XCTAssertEqual(
            AgentTurnContract.local(LocalIntelligenceResult(reply: "我可以帮你分析。", suggestion: nil)).intents,
            [.answer("我可以帮你分析。")]
        )
    }

    func testLocalFutureWorkoutIntentStaysDistinctFromCompletedWorkout() {
        let turn = AgentTurnContract.local(
            LocalIntelligenceResult(
                reply: "我识别到一个未来训练计划建议。",
                suggestion: LocalRecordSuggestion(
                    kind: .workoutPlan,
                    item: "明天轻松步行",
                    amount: "30 分钟"
                )
            )
        )

        XCTAssertEqual(
            turn.intents,
            [.captureProposal(
                LocalRecordSuggestion(kind: .workoutPlan, item: "明天轻松步行", amount: "30 分钟")
            )]
        )
        XCTAssertTrue(turn.stagedActionIDs.isEmpty)
    }

    func testDomainIntentUsesClosedCodableContract() throws {
        let intent = AgentIntent.recordWeight(
            WeightDraft(measuredAt: Date(timeIntervalSince1970: 1), kilograms: 62)
        )
        let encoded = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(AgentIntent.self, from: encoded)

        XCTAssertEqual(decoded, intent)
    }

    func testCaptureProposalCodableDoesNotPromoteItToAnAction() throws {
        let intent = AgentIntent.captureProposal(
            LocalRecordSuggestion(kind: .meal, item: "米饭", amount: nil)
        )

        XCTAssertEqual(try JSONDecoder().decode(AgentIntent.self, from: JSONEncoder().encode(intent)), intent)
        guard case .captureProposal(_) = intent else { return XCTFail("Expected a proposal intent") }
    }
}
