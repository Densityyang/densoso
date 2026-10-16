import XCTest
@testable import Densoso

final class AgentReasoningPolicyTests: XCTestCase {
    func testWeightLoggingUsesNoReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("记录体重 62.5kg"), .none)
    }

    func testHealthAnalysisUsesHighReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("分析我的恢复情况"), .high)
    }

    func testLongRangeTrainingPlanUsesMaximumReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("帮我制定训练周期"), .max)
    }

    func testOrdinaryQuestionUsesLowReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("今天有什么安排？"), .low)
    }
}
