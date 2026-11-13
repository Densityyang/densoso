import DensosoDomain
import XCTest
@testable import Densoso

final class MealCalorieSummaryPresentationTests: XCTestCase {
    func testWideRangeKeepsLikelyAndConfidenceSeparateFromExpandableRange() throws {
        let summary = MealCalorieSummaryPresentation(
            energyRange: try EstimateRange(low: 100, likely: 400, high: 1_000)
        )

        XCTAssertEqual(summary.likelyText, "约 400 kcal")
        XCTAssertEqual(summary.confidenceText, "估算可信度：低")
        XCTAssertEqual(summary.detailsTitle, "估算区间详情")
        XCTAssertEqual(summary.rangeDetailsText, "热量范围：100–1000 kcal")
        XCTAssertFalse(summary.likelyText.contains("100–1000"))
        XCTAssertFalse(summary.confidenceText.contains("100–1000"))
    }
}
