import DensosoDomain
import XCTest
@testable import Densoso

final class ConfirmedMealCalorieCorrectionTests: XCTestCase {
    func testCorrectionScalesOnlyEnergyAndRecordsAuditableUserEvidence() throws {
        let original = try EstimateRange(low: 300, likely: 400, high: 600)
        let correction = try ConfirmedMealCalorieCorrection(
            originalEnergy: original,
            correctedLikelyKcal: 500,
            occurredAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(correction.factor, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(correction.originalEnergy, original)
        XCTAssertEqual(correction.correctedEnergy.low, 375, accuracy: 0.000_001)
        XCTAssertEqual(correction.correctedEnergy.likely, 500, accuracy: 0.000_001)
        XCTAssertEqual(correction.correctedEnergy.high, 750, accuracy: 0.000_001)
        XCTAssertEqual(correction.evidence.grade, .userReported)
        XCTAssertEqual(correction.evidence.sourceID, ConfirmedMealCalorieCorrection.evidenceSourceID)
        XCTAssertEqual(correction.evidence.sourceVersion, ConfirmedMealCalorieCorrection.evidenceSourceVersion)
        XCTAssertTrue(correction.evidence.summary.contains("1970-01-01T00:00:00Z"))
        XCTAssertTrue(correction.evidence.summary.contains(
            "热量范围 300–600（likely 400） kcal → 375–750（likely 500） kcal"
        ))
        XCTAssertTrue(correction.evidence.summary.contains("蛋白质、脂肪和碳水估算未调整"))
        XCTAssertTrue(correction.evidence.summary.contains("菜品和食材份量保持原记录"))
    }

    func testCorrectionRejectsInvalidUnchangedAndExtremeValues() throws {
        let original = try EstimateRange(low: 300, likely: 400, high: 600)

        XCTAssertThrowsError(
            try ConfirmedMealCalorieCorrection(
                originalEnergy: original,
                correctedLikelyKcal: 0,
                occurredAt: Date(timeIntervalSince1970: 0)
            )
        ) { error in
            XCTAssertEqual(error as? ConfirmedMealCalorieCorrectionError, .invalidCorrectedValue)
        }
        XCTAssertThrowsError(
            try ConfirmedMealCalorieCorrection(
                originalEnergy: original,
                correctedLikelyKcal: 400,
                occurredAt: Date(timeIntervalSince1970: 0)
            )
        ) { error in
            XCTAssertEqual(error as? ConfirmedMealCalorieCorrectionError, .unchangedValue)
        }
        XCTAssertThrowsError(
            try ConfirmedMealCalorieCorrection(
                originalEnergy: original,
                correctedLikelyKcal: 5_000,
                occurredAt: Date(timeIntervalSince1970: 0)
            )
        ) { error in
            XCTAssertEqual(error as? ConfirmedMealCalorieCorrectionError, .correctionOutOfRange)
        }
    }
}
