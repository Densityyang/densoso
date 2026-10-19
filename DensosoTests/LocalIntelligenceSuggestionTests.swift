import XCTest
@testable import Densoso

final class LocalIntelligenceSuggestionTests: XCTestCase {
    private let parser = LocalRecordSuggestionParser()

    func testParsesMealSuggestionWithoutCreatingARecord() {
        let suggestion = parser.parse(
            category: "meal",
            item: " 米饭 ",
            amount: "200 克",
            userText: "今天午餐吃了米饭200克"
        )

        XCTAssertEqual(suggestion?.kind, .meal)
        XCTAssertEqual(suggestion?.item, "米饭")
        XCTAssertEqual(suggestion?.amount, "200 克")
    }

    func testParsesWorkoutSuggestionWithoutAnInventedAmount() {
        let suggestion = parser.parse(
            category: "workoutPlan",
            item: "明天轻松步行",
            amount: "",
            userText: "计划明天轻松步行"
        )

        XCTAssertEqual(suggestion?.kind, .workoutPlan)
        XCTAssertEqual(suggestion?.item, "明天轻松步行")
        XCTAssertNil(suggestion?.amount)
    }

    func testRejectsUnknownCategoryAndBlankItem() {
        XCTAssertNil(parser.parse(category: "none", item: "", amount: "", userText: "我吃了米饭"))
        XCTAssertNil(parser.parse(category: "meal", item: "  ", amount: "200 克", userText: "我吃了米饭"))
        XCTAssertNil(parser.parse(category: "workout", item: "跑步", amount: "30 分钟", userText: "计划明天跑步"))
    }

    func testDoesNotTurnCompletedWorkoutOrUneatenMealIntoCaptureProposal() {
        let completedWorkoutExamples = ["我今天跑了30分钟", "我今天完成了训练计划", "I finished my workout today"]
        for userText in completedWorkoutExamples {
            XCTAssertNil(parser.parse(
                category: "workoutPlan",
                item: "跑步",
                amount: "30 分钟",
                userText: userText
            ))
        }
        XCTAssertNil(
            parser.parse(
                category: "meal",
                item: "早餐",
                amount: "",
                userText: "我还没吃早餐"
            )
        )
    }
}
