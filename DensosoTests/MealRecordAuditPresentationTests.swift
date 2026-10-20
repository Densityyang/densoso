import DensosoDomain
import XCTest
@testable import Densoso

final class MealRecordAuditPresentationTests: XCTestCase {
    func testMealRecordPresentationShowsSanitizedSourcesAndAlgorithmVersion() throws {
        let evidence = [
            EvidenceSnapshot(
                grade: .estimated,
                sourceID: "agent-image:nutritionLabel",
                summary: "PRIVATE OCR CONTENT MUST NOT BE SHOWN",
                confidence: 0.8
            ),
            EvidenceSnapshot(
                grade: .databaseMatch,
                sourceID: "food-resolver-v2:123",
                summary: "private food label",
                confidence: 0.9
            ),
            EvidenceSnapshot(
                grade: .userReported,
                sourceID: "user-corrected-portion",
                summary: "private user correction",
                confidence: 1
            ),
        ]
        let data = try JSONEncoder().encode(evidence)

        let summary = MealRecordAuditPresentation.summary(
            evidenceData: data,
            algorithmVersion: "meal-estimator-v2"
        )

        XCTAssertEqual(
            summary,
            "来源：餐食照片、本地食物库、用户补充 · 算法：meal-estimator-v2"
        )
        XCTAssertFalse(summary.contains("PRIVATE"))
        XCTAssertFalse(summary.contains("private"))
        XCTAssertFalse(summary.contains("agent-image"))
    }
}
