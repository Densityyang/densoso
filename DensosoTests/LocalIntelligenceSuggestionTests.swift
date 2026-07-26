import XCTest
@testable import Densoso

final class LocalIntelligenceSuggestionTests: XCTestCase {
    private let parser = LocalRecordSuggestionParser()

    func testParsesMealSuggestionWithoutCreatingARecord() {
        let suggestion = parser.parse(category: "meal", item: " 米饭 ", amount: "200 克")

        XCTAssertEqual(suggestion?.kind, .meal)
        XCTAssertEqual(suggestion?.item, "米饭")
        XCTAssertEqual(suggestion?.amount, "200 克")
    }

    func testParsesWorkoutSuggestionWithoutAnInventedAmount() {
        let suggestion = parser.parse(category: "workout", item: "深蹲", amount: "")

        XCTAssertEqual(suggestion?.kind, .workout)
        XCTAssertEqual(suggestion?.item, "深蹲")
        XCTAssertNil(suggestion?.amount)
    }

    func testRejectsUnknownCategoryAndBlankItem() {
        XCTAssertNil(parser.parse(category: "none", item: "", amount: ""))
        XCTAssertNil(parser.parse(category: "meal", item: "  ", amount: "200 克"))
    }
}
