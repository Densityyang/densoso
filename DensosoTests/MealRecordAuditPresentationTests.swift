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

    func testUserConfirmedPortionCorrectionIsPresentedAsCalibration() throws {
        let correction = try XCTUnwrap(MealPortionPriorCorrection(
            unit: "bowl",
            unitCount: 1,
            totalGrams: 186
        ))
        let evidenceData = try JSONEncoder().encode([correction.evidenceSnapshot])

        let summary = MealRecordAuditPresentation.summary(
            evidenceData: evidenceData,
            algorithmVersion: "meal-estimator-v3"
        )

        XCTAssertTrue(summary.contains("个人份量校准"))
        XCTAssertFalse(summary.contains("估算使用个人先验"))
        XCTAssertEqual(
            MealRecordAuditPresentation.portionCalibrationSummary(evidenceData: evidenceData),
            "个人份量校准：1碗 = 186 g"
        )
    }

    func testPriorUsageIsPresentedAsEstimateWithSelectedRangeAndVersion() throws {
        let prior = HouseholdPortionPrior(
            unit: "bowl",
            p10Grams: 160,
            p50Grams: 200,
            p90Grams: 240,
            version: "portion-prior-v7"
        )
        let usage = try XCTUnwrap(MealPortionPriorUsage(prior: prior, count: 1))
        let usageSnapshot = usage.evidenceSnapshot
        XCTAssertEqual(usageSnapshot.grade, .weak)
        XCTAssertEqual(usageSnapshot.confidence, 0.4)
        XCTAssertEqual(MealPortionPriorUsage.usage(from: usageSnapshot), usage)
        let evidenceData = try JSONEncoder().encode([usageSnapshot])

        let summary = MealRecordAuditPresentation.summary(
            evidenceData: evidenceData,
            algorithmVersion: "meal-estimator-v3"
        )

        XCTAssertTrue(summary.contains("来源：个人份量先验"))
        XCTAssertTrue(summary.contains("估算使用个人先验：1碗"))
        XCTAssertTrue(summary.contains("P10/P50/P90 160/200/240 g"))
        XCTAssertTrue(summary.contains("portion-prior-v7"))
        XCTAssertFalse(summary.contains("个人份量校准"))
        XCTAssertNil(MealRecordAuditPresentation.portionCalibrationSummary(evidenceData: evidenceData))
    }

    func testUnsupportedPriorUsageSnapshotShowsOnlyGenericEstimateWording() throws {
        let unsupported = EvidenceSnapshot(
            grade: .estimated,
            sourceID: MealPortionPriorUsage.evidenceSourceID,
            sourceVersion: "unknown-version",
            summary: "PRIVATE RAW SNAPSHOT MUST NOT BE SHOWN",
            confidence: 0.65
        )
        let evidenceData = try JSONEncoder().encode([unsupported])

        let summary = MealRecordAuditPresentation.summary(
            evidenceData: evidenceData,
            algorithmVersion: "meal-estimator-v3"
        )

        XCTAssertTrue(summary.contains("个人份量先验"))
        XCTAssertTrue(summary.contains("估算使用个人先验"))
        XCTAssertFalse(summary.contains("P10/P50/P90"))
        XCTAssertFalse(summary.contains("PRIVATE RAW SNAPSHOT"))
    }
}
