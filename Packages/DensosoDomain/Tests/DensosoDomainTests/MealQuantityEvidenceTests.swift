import Foundation
import XCTest
@testable import DensosoDomain

final class MealQuantityEvidenceTests: XCTestCase {
    func testV2MealAlgorithmVersionsAreExplicit() {
        XCTAssertEqual(MealEstimator.algorithmVersion, "meal-estimator-v2")
        XCTAssertEqual(PortionEstimator.algorithmVersion, "portion-estimator-v2")
        XCTAssertEqual(CaloriePresentationPolicy.algorithmVersion, "calorie-accounting-v3")
    }

    func testCaloriePresentationUsesLikelyPointAndRelativeWidthThresholds() throws {
        let policy = CaloriePresentationPolicy()

        XCTAssertEqual(
            policy.presentation(for: try EstimateRange(low: 82.5, likely: 100, high: 117.5)),
            .likely(kcal: 100, confidence: .high)
        )
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange(low: 67.5, likely: 100, high: 132.5)),
            .likely(kcal: 100, confidence: .medium)
        )
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange(low: 60, likely: 100, high: 130)),
            .needsClarification(likelyKcal: 100)
        )
    }

    func testMealSummaryCarriesLikelyValueAndTextConfidenceWithoutFalseZero() throws {
        let estimate = try EstimateRange(low: 70, likely: 100, high: 130)
        let dish = MealDishDraft(
            name: "米饭",
            nutrients: NutrientEstimate(energyKcal: estimate),
            algorithmVersion: MealEstimator.algorithmVersion
        )
        let payload = ActionPayload.meal(MealDraft(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            mealType: "lunch",
            dishes: [dish]
        ))

        XCTAssertEqual(payload.confidence, 0.65)
        XCTAssertTrue(payload.summary.contains("约 100 kcal，可信度中"))
        XCTAssertEqual(
            MealDraft(occurredAt: Date(), mealType: "lunch", dishes: []).caloriePresentation,
            nil
        )
        XCTAssertFalse(ActionPayload.meal(MealDraft(
            occurredAt: Date(),
            mealType: "lunch",
            dishes: []
        )).summary.contains("0 kcal"))
    }

    func testExplicitGramsParserRequiresCurrentUnhedgedAmountAttachedToIngredient() {
        let parser = ExplicitUserGramsParser()

        XCTAssertEqual(
            parser.exactGrams(in: "午饭的米饭186克，鸡蛋2个", matching: ["米饭", "熟米饭"]),
            186
        )
        XCTAssertEqual(
            parser.exactGrams(in: "186g 米饭，另外有鸡蛋", matching: ["米饭"]),
            186
        )
        XCTAssertEqual(parser.exactGrams(in: "这道菜用了油8克", matching: ["油"]), 8)
        XCTAssertNil(parser.exactGrams(in: "米饭大约186克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "约米饭186克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "米饭186克左右", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "不是米饭186克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "别按米饭重186克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "米饭200克或250克米饭", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "rice 200g or 250g rice", matching: ["rice"]))
        XCTAssertNil(parser.exactGrams(in: "rice 200g to 250g rice", matching: ["rice"]))
        XCTAssertNil(parser.exactGrams(in: "rice 200–250g", matching: ["rice"]))
        XCTAssertNil(parser.exactGrams(in: "鸡蛋 186 克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "米饭186克或200克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "米饭100克、米饭100克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "米饭100-120克", matching: ["米饭"]))
        XCTAssertNil(parser.exactGrams(in: "米饭 186 kcal", matching: ["米饭"]))
    }

    func testModelExactGramClaimRemainsApproximateUntilUserTextIsValidated() throws {
        let resolver = MealQuantityEvidenceResolver()
        let claim = MealQuantityEvidence(kind: .exactGrams, value: 180, unit: "g")

        let modelOnly = try resolver.resolve(claim)
        let approximate = try PortionEstimator().estimate(evidence: [modelOnly])
        XCTAssertEqual(approximate.source, .modelEstimate)
        XCTAssertFalse(approximate.isMeasured)
        XCTAssertEqual(approximate.lowGrams, 63, accuracy: 0.001)
        XCTAssertEqual(approximate.likelyGrams, 180, accuracy: 0.001)
        XCTAssertEqual(approximate.highGrams, 297, accuracy: 0.001)

        let catalogEntry = FoodCatalogEntry(
            id: "rice",
            name: "rice",
            preparation: .cooked,
            category: "grain",
            nutrients: FoodNutrientProfile(energyKcalPer100Grams: 130),
            sourceVersion: "fixture-v1"
        )
        let resolution = FoodResolver(catalog: [catalogEntry]).resolve(
            FoodResolutionQuery(label: "rice", preparation: .cooked, sourceQuality: 1)
        )
        let dish = try MealEstimator().estimateDish(
            MealDishEstimationInput(
                name: "rice",
                ingredients: [
                    MealIngredientEstimationInput(
                        label: "rice",
                        resolution: resolution,
                        portion: approximate,
                        massBasis: .cooked
                    ),
                ]
            )
        )
        let portionEvidence = try XCTUnwrap(dish.ingredients.first?.evidence.first {
            $0.sourceID == "portion:modelEstimate"
        })
        XCTAssertEqual(portionEvidence.grade, .weak)

        let verified = try resolver.resolve(claim, validatedUserReportedGrams: 186)
        let exact = try PortionEstimator().estimate(evidence: [verified])
        XCTAssertEqual(exact.source, .userReportedExact)
        XCTAssertFalse(exact.isMeasured)
        XCTAssertEqual(exact.lowGrams, 186, accuracy: 0.001)
        XCTAssertEqual(exact.likelyGrams, 186, accuracy: 0.001)
        XCTAssertEqual(exact.highGrams, 186, accuracy: 0.001)
    }

    func testHouseholdAndCountEvidenceUseVersionedRanges() throws {
        let resolver = MealQuantityEvidenceResolver()
        let household = try resolver.resolve(
            MealQuantityEvidence(kind: .household, value: 1, unit: "bowl")
        )
        let householdEstimate = try PortionEstimator().estimate(evidence: [household])
        XCTAssertEqual(householdEstimate.source, .householdPrior)
        XCTAssertEqual(householdEstimate.lowGrams, 100, accuracy: 0.001)
        XCTAssertEqual(householdEstimate.likelyGrams, 160, accuracy: 0.001)
        XCTAssertEqual(householdEstimate.highGrams, 240, accuracy: 0.001)

        let count = try resolver.resolve(
            MealQuantityEvidence(kind: .count, value: 2, unit: "egg")
        )
        let countEstimate = try PortionEstimator().estimate(evidence: [count])
        XCTAssertEqual(countEstimate.source, .householdPrior)
        XCTAssertEqual(countEstimate.lowGrams, 80, accuracy: 0.001)
        XCTAssertEqual(countEstimate.likelyGrams, 104, accuracy: 0.001)
        XCTAssertEqual(countEstimate.highGrams, 136, accuracy: 0.001)
        XCTAssertFalse(countEstimate.isMeasured)
    }

    func testPackageServingUsesLocalLabelWhenVerifiedAndRangeOtherwise() throws {
        let resolver = MealQuantityEvidenceResolver()
        let servingParser = PackageServingGramsParser()
        XCTAssertEqual(servingParser.gramsPerServing(in: "每份 42g；能量 200 kcal"), 42)
        XCTAssertEqual(servingParser.gramsPerServing(in: "Serving size: 40 g"), 40)
        XCTAssertNil(servingParser.gramsPerServing(in: "每份 40g\n每100g 能量 200 kcal"))
        XCTAssertNil(servingParser.gramsPerServing(in: "每份 40g 或 50g"))

        let package = MealQuantityEvidence(
            kind: .packageServing,
            value: 2,
            unit: "serving",
            gramsPerServing: 40
        )

        let verified = try resolver.resolve(package, validatedPackageGramsPerServing: 42)
        let packageEstimate = try PortionEstimator().estimate(evidence: [verified])
        XCTAssertEqual(packageEstimate.source, .packageServing)
        XCTAssertEqual(packageEstimate.lowGrams, 79.8, accuracy: 0.001)
        XCTAssertEqual(packageEstimate.likelyGrams, 84, accuracy: 0.001)
        XCTAssertEqual(packageEstimate.highGrams, 88.2, accuracy: 0.001)

        for unit in ["pack", "package", "包"] {
            let packEvidence = try resolver.resolve(
                MealQuantityEvidence(kind: .packageServing, value: 1, unit: unit),
                validatedPackageGramsPerServing: 40
            )
            XCTAssertEqual(
                try PortionEstimator().estimate(evidence: [packEvidence]).source,
                .packageServing
            )
        }

        XCTAssertThrowsError(try resolver.resolve(package)) {
            XCTAssertEqual(
                $0 as? MealQuantityEvidenceResolutionError,
                .missingPortionEvidence
            )
        }
    }

    func testPhotoEstimateUsesWideRangeAndUnknownRequiresClarification() throws {
        let resolver = MealQuantityEvidenceResolver()
        let photo = try resolver.resolve(
            MealQuantityEvidence(kind: .photoEstimate, value: 180, unit: "g")
        )
        let photoEstimate = try PortionEstimator().estimate(evidence: [photo])
        XCTAssertEqual(photoEstimate.source, .photoWithoutScale)
        XCTAssertEqual(photoEstimate.lowGrams, 63, accuracy: 0.001)
        XCTAssertEqual(photoEstimate.likelyGrams, 180, accuracy: 0.001)
        XCTAssertEqual(photoEstimate.highGrams, 297, accuracy: 0.001)
        XCTAssertFalse(photoEstimate.isMeasured)

        XCTAssertThrowsError(
            try resolver.resolve(MealQuantityEvidence(kind: .unknown))
        ) {
            XCTAssertEqual(
                $0 as? MealQuantityEvidenceResolutionError,
                .missingPortionEvidence
            )
        }

        let explicitAmount = try resolver.resolve(
            MealQuantityEvidence(kind: .unknown),
            validatedUserReportedGrams: 186
        )
        XCTAssertEqual(
            try PortionEstimator().estimate(evidence: [explicitAmount]).source,
            .userReportedExact
        )

        let answeredUnknown = try resolver.resolve(
            MealQuantityEvidence(kind: .unknown, value: 180, unit: "g"),
            allowLowConfidenceModelEstimate: true
        )
        XCTAssertEqual(
            try PortionEstimator().estimate(evidence: [answeredUnknown]).source,
            .modelEstimate
        )
    }

    func testUnknownHouseholdUnitAndInvalidClaimsDoNotCreatePortions() {
        let resolver = MealQuantityEvidenceResolver()

        XCTAssertThrowsError(
            try resolver.resolve(MealQuantityEvidence(kind: .household, value: 1, unit: "plate"))
        ) {
            XCTAssertEqual(
                $0 as? MealQuantityEvidenceResolutionError,
                .missingPortionEvidence
            )
        }
        XCTAssertThrowsError(
            try resolver.resolve(MealQuantityEvidence(kind: .photoEstimate, value: .infinity, unit: "g"))
        ) {
            XCTAssertEqual(
                $0 as? MealQuantityEvidenceResolutionError,
                .invalidQuantityEvidence
            )
        }
        XCTAssertThrowsError(
            try resolver.resolve(
                MealQuantityEvidence(kind: .exactGrams, value: 100, unit: "g"),
                validatedUserReportedGrams: 5_001
            )
        ) {
            XCTAssertEqual(
                $0 as? MealQuantityEvidenceResolutionError,
                .invalidQuantityEvidence
            )
        }
    }
}
