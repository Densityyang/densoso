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

    func testDishPriorUsageShowsSanitizedIngredientRangeAndLearningProvenance() throws {
        let ingredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "tomato-id",
            name: "番茄",
            lowGrams: 70,
            likelyGrams: 85,
            highGrams: 100,
            preparation: .cooked,
            massBasis: .cooked,
            sourceID: "food-table",
            sourceRecordID: "tomato-001",
            sourceVersion: "food-table-v1",
            licenseStatus: "verified"
        ))
        let key = try XCTUnwrap(MealDishPriorStorageKey.make(
            dishName: "番茄炒蛋",
            cookingMethod: "stirFry",
            ingredients: [ingredient]
        ))
        let prior = try XCTUnwrap(PersonalMealDishPrior(
            id: UUID(),
            priorKey: key.priorKey,
            dishKey: key.dishKey,
            dishName: "番茄炒蛋",
            cookingMethod: "stirFry",
            ingredients: [ingredient],
            observationCount: 2,
            isUserManaged: false,
            sourceActionKey: "private-action-key",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_100)
        ))
        let usage = try XCTUnwrap(PersonalMealDishPriorUsage(prior: prior, ingredient: ingredient))
        let evidenceData = try JSONEncoder().encode([usage.evidenceSnapshot])

        let summary = MealRecordAuditPresentation.summary(
            evidenceData: evidenceData,
            algorithmVersion: "meal-estimator-v3"
        )

        XCTAssertTrue(summary.contains("来源：个人菜品模板"))
        XCTAssertTrue(summary.contains("估算使用个人菜品模板：番茄炒蛋 · 番茄 70/85/100 g（熟重）"))
        XCTAssertTrue(summary.contains("重复确认 2 次"))
        XCTAssertFalse(summary.contains("private-action-key"))
        XCTAssertFalse(summary.contains("personal-meal-dish-prior-used"))
    }

    func testDishPriorUsageRejectsUnverifiedBasisAndMalformedStoredRanges() throws {
        let ingredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "tomato-id",
            name: "番茄",
            lowGrams: 70,
            likelyGrams: 85,
            highGrams: 100,
            preparation: .cooked,
            massBasis: .cooked,
            sourceID: "food-table",
            sourceRecordID: "tomato-001",
            sourceVersion: "food-table-v1",
            licenseStatus: "verified"
        ))
        let key = try XCTUnwrap(MealDishPriorStorageKey.make(
            dishName: "番茄炒蛋",
            cookingMethod: "stirFry",
            ingredients: [ingredient]
        ))
        let prior = try XCTUnwrap(PersonalMealDishPrior(
            id: UUID(),
            priorKey: key.priorKey,
            dishKey: key.dishKey,
            dishName: "番茄炒蛋",
            cookingMethod: "stirFry",
            ingredients: [ingredient],
            observationCount: 2,
            isUserManaged: false,
            sourceActionKey: nil,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_100)
        ))
        let validUsage = try XCTUnwrap(PersonalMealDishPriorUsage(prior: prior, ingredient: ingredient))
        let validData = try XCTUnwrap(validUsage.evidenceSnapshot.summary.data(using: .utf8))
        var invalidBasisObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        invalidBasisObject["licenseStatus"] = "unverified"
        let invalidBasisData = try JSONSerialization.data(withJSONObject: invalidBasisObject)
        let invalidBasisSummary = try XCTUnwrap(String(data: invalidBasisData, encoding: .utf8))
        let invalidBasisEvidence = EvidenceSnapshot(
            grade: .weak,
            sourceID: PersonalMealDishPriorUsage.evidenceSourceID,
            sourceVersion: validUsage.version,
            summary: invalidBasisSummary
        )

        var invalidRangeObject = invalidBasisObject
        invalidRangeObject["licenseStatus"] = "verified"
        invalidRangeObject["lowGrams"] = 120
        let invalidRangeData = try JSONSerialization.data(withJSONObject: invalidRangeObject)
        let invalidRangeEvidence = EvidenceSnapshot(
            grade: .weak,
            sourceID: PersonalMealDishPriorUsage.evidenceSourceID,
            sourceVersion: validUsage.version,
            summary: try XCTUnwrap(String(data: invalidRangeData, encoding: .utf8))
        )

        XCTAssertNil(PersonalMealDishPriorUsage.usage(from: invalidBasisEvidence))
        XCTAssertNil(PersonalMealDishPriorUsage.usage(from: invalidRangeEvidence))
        let summary = MealRecordAuditPresentation.summary(
            evidenceData: try JSONEncoder().encode([invalidBasisEvidence, invalidRangeEvidence]),
            algorithmVersion: "meal-estimator-v3"
        )
        XCTAssertTrue(summary.contains("估算使用个人菜品模板"))
        XCTAssertFalse(summary.contains("unverified"))
    }
}
