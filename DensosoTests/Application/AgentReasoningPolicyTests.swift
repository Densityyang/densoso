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

    func testMealDraftUsesLowReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("记录午餐：吃了鸡蛋和米饭"), .low)
    }

    func testIntentExtractionUsesNoReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("只提取意图：给我健康建议"), .none)
    }

    func testDailyRecommendationUsesHighReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("今天应该怎么安排训练？"), .high)
    }

    func testComplexPlanningUsesMaximumReasoning() {
        XCTAssertEqual(AgentReasoningPolicy.forUserMessage("帮我制定一个8周训练计划"), .max)
    }
}
