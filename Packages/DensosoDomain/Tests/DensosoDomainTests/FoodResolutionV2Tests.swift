import Foundation
import XCTest
@testable import DensosoDomain

final class FoodResolutionV2Tests: XCTestCase {
    func testAliasAndCategoryHaveSeparateScoreAxes() {
        let bar = entry(
            id: "oat-bar",
            localFoodID: "food-oat-bar",
            name: "oatmeal bar",
            aliases: ["oat bar"],
            preparation: .unknown,
            edibleFraction: 1
        )
        let result = FoodResolverV2(catalog: [bar]).resolve(
            FoodResolutionV2Query(
                label: "oat bar",
                categoryHint: "snack",
                sourceQuality: 1
            )
        )

        let score = try! XCTUnwrap(result.candidates.first?.score)
        XCTAssertEqual(score.lexical, 1)
        XCTAssertEqual(score.alias, 1)
        XCTAssertEqual(score.category, 1)
        XCTAssertEqual(result.autoPreselect?.entry.id, bar.id)
    }

    func testV2ScoreAxesSurviveMealResolverAndDraftBridges() throws {
        let rice = entry(
            id: "rice-cooked",
            localFoodID: "food-rice-cooked",
            name: "rice",
            aliases: ["cooked rice"],
            preparation: .cooked,
            edibleFraction: 1
        )
        let resolution = FoodResolverV2(catalog: [rice]).resolve(
            FoodResolutionV2Query(
                label: "rice",
                preparation: .cooked,
                massBasis: .cooked,
                sourceQuality: 1
            )
        )
        let v2Candidate = try XCTUnwrap(resolution.candidates.first)
        let mealResolution = resolution.mealEstimatorResolution
        XCTAssertEqual(mealResolution.candidates.first?.resolutionScoreV2, v2Candidate.score)

        let portion = try PortionEstimate(
            lowGrams: 100,
            likelyGrams: 120,
            highGrams: 140,
            isMeasured: false
        )
        let draft = try MealEstimator().estimateDish(
            MealDishEstimationInput(
                name: "rice",
                ingredients: [
                    MealIngredientEstimationInput(
                        label: "rice",
                        resolution: mealResolution,
                        portion: portion,
                        massBasis: .cooked
                    ),
                ]
            )
        )
        XCTAssertEqual(draft.ingredients.first?.foodResolutionScoreV2, v2Candidate.score)

        let roundTrip = try JSONDecoder().decode(MealDishDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(roundTrip.ingredients.first?.foodResolutionScoreV2, v2Candidate.score)
    }

    func testMassBasisAndPreparationCompatibilityRankCookedFood() {
        let cooked = entry(
            id: "rice-cooked",
            localFoodID: "food-cooked",
            name: "rice",
            aliases: ["cooked rice"],
            preparation: .cooked,
            edibleFraction: 1
        )
        let raw = entry(
            id: "rice-raw",
            localFoodID: "food-raw",
            name: "rice",
            aliases: ["raw rice"],
            preparation: .raw,
            edibleFraction: 0.98
        )

        let result = FoodResolverV2(catalog: [raw, cooked]).resolve(
            FoodResolutionV2Query(
                label: "rice",
                preparation: .cooked,
                massBasis: .cooked,
                sourceQuality: 0.8
            )
        )

        XCTAssertEqual(result.candidates.first?.entry.id, cooked.id)
        XCTAssertEqual(result.candidates.first?.score.preparation, 1)
        XCTAssertEqual(result.candidates.first?.score.massBasis, 1)
        XCTAssertEqual(result.candidates.last?.score.preparation, 0)
        XCTAssertEqual(result.autoPreselect?.entry.id, cooked.id)
        XCTAssertTrue(result.requiresConfirmation)

        let purchasedBasis = FoodResolverV2(catalog: [raw, cooked]).resolve(
            FoodResolutionV2Query(
                label: "rice",
                massBasis: .asPurchased,
                sourceQuality: 0.8
            )
        )
        XCTAssertTrue(purchasedBasis.candidates.allSatisfy { $0.score.massBasis == 1 })
    }

    func testConfirmedFoodHistoryContributesIndependentV2Score() {
        let cooked = entry(
            id: "food-a",
            localFoodID: "food-a",
            name: "rice",
            aliases: ["white rice"],
            preparation: .unknown,
            edibleFraction: 1
        )
        let userConfirmed = entry(
            id: "food-b",
            localFoodID: "food-b",
            name: "rice",
            aliases: ["brown rice"],
            preparation: .unknown,
            edibleFraction: 1
        )

        let result = FoodResolverV2(catalog: [cooked, userConfirmed]).resolve(
            FoodResolutionV2Query(
                label: "rice",
                preparation: .unknown,
                sourceQuality: 0.8,
                confirmedHistoryFoodIDs: ["food-b"]
            )
        )

        XCTAssertEqual(result.candidates.first?.entry.id, "food-b")
        XCTAssertEqual(result.candidates.first?.score.history, 1)
        XCTAssertEqual(result.candidates.last?.score.history, 0)
        XCTAssertNil(result.autoPreselect, "A 0.05 history advantage must not bypass the 0.12 ambiguity margin")
    }

    func testLocalLabelAndVisualEvidenceScoreCandidateWithoutReturningRawText() {
        let privateOCR = "PRIVATE-NUTRITION-LABEL-TEXT"
        let oatmeal = entry(
            id: "oatmeal-bar",
            localFoodID: "food-oatmeal-bar",
            name: "oatmeal bar",
            aliases: ["oat bar"],
            preparation: .unknown,
            edibleFraction: 1
        )
        let result = FoodResolverV2(catalog: [oatmeal]).resolve(
            FoodResolutionV2Query(
                label: "oat bar",
                sourceQuality: 0.5,
                evidence: [
                    MealEvidence(
                        kind: .nutritionLabel,
                        value: "\(privateOCR) oat bar nutrition facts",
                        confidence: 0.96,
                        sourceVersion: "local-label-v2"
                    ),
                    MealEvidence(
                        kind: .foodCandidate,
                        value: "oatmeal bar",
                        confidence: 0.82,
                        sourceVersion: "local-vision-v2"
                    ),
                ]
            )
        )

        let candidate = try! XCTUnwrap(result.candidates.first)
        XCTAssertGreaterThanOrEqual(candidate.score.evidence, 0.96)
        XCTAssertEqual(candidate.evidence.first?.grade, .label)
        XCTAssertFalse(candidate.evidence.contains { $0.summary.contains(privateOCR) })
        XCTAssertFalse(candidate.evidence.contains { $0.sourceVersion == privateOCR })
        XCTAssertTrue(result.requiresConfirmation)
    }

    func testShortASCIINameInsideAnUnrelatedLabelDoesNotBoostEvidence() {
        let oil = FoodCatalogEntry(
            id: "oil",
            name: "oil",
            preparation: .unknown,
            category: "ingredient",
            nutrients: FoodNutrientProfile(energyKcalPer100Grams: 884),
            sourceVersion: "fixture-v1"
        )
        let result = FoodResolverV2(catalog: [oil]).resolve(
            FoodResolutionV2Query(
                label: "oil",
                sourceQuality: 0,
                evidence: [
                    MealEvidence(
                        kind: .nutritionLabel,
                        value: "boiling water nutrition facts",
                        confidence: 0.99
                    ),
                ]
            )
        )

        let candidate = try! XCTUnwrap(result.candidates.first)
        XCTAssertLessThan(candidate.score.evidence, 0.99)
        XCTAssertFalse(candidate.evidence.contains { $0.sourceID == "food-evidence-v2:nutritionLabel" })

        let unrelatedCatalogMatch = FoodResolverV2(catalog: [
            FoodCatalogEntry(
                id: "boiling-water",
                name: "boiling water",
                preparation: .unknown,
                category: "drink",
                nutrients: FoodNutrientProfile(energyKcalPer100Grams: 0),
                sourceVersion: "fixture-v1"
            ),
        ]).resolve(FoodResolutionV2Query(label: "oil"))
        XCTAssertTrue(unrelatedCatalogMatch.candidates.isEmpty)

        let shortSubstringMatch = FoodResolverV2(catalog: [
            FoodCatalogEntry(
                id: "steak",
                name: "steak",
                preparation: .unknown,
                category: "meat",
                nutrients: FoodNutrientProfile(energyKcalPer100Grams: 250),
                sourceVersion: "fixture-v1"
            ),
        ]).resolve(FoodResolutionV2Query(label: "tea"))
        XCTAssertTrue(shortSubstringMatch.candidates.isEmpty)
    }

    func testBarcodeMatchCanResolveLabelWithoutChangingConfirmationRequirement() {
        let rice = entry(
            id: "catalog-rice",
            localFoodID: "food-rice",
            name: "rice",
            aliases: [],
            preparation: .cooked,
            edibleFraction: 1
        )
        let result = FoodResolverV2(catalog: [rice]).resolve(
            FoodResolutionV2Query(
                label: "unreadable product",
                barcodeMatchedFoodID: "food-rice"
            )
        )

        XCTAssertEqual(result.autoPreselect?.entry.id, rice.id)
        XCTAssertEqual(result.autoPreselect?.score.evidence, 1)
        XCTAssertEqual(result.autoPreselect?.evidence.first?.sourceID, "barcode")
        XCTAssertTrue(result.requiresConfirmation)
        XCTAssertEqual(result.mealEstimatorResolution.autoPreselect?.entry.id, rice.id)
    }

    func testCloseCandidatesStayUnresolvedAndRequireConfirmation() {
        let first = entry(
            id: "rice-a",
            localFoodID: "rice-a",
            name: "rice",
            aliases: [],
            preparation: .cooked,
            edibleFraction: 1
        )
        let second = entry(
            id: "rice-b",
            localFoodID: "rice-b",
            name: "rice",
            aliases: [],
            preparation: .cooked,
            edibleFraction: 1
        )

        let result = FoodResolverV2(catalog: [first, second]).resolve(
            FoodResolutionV2Query(
                label: "rice",
                preparation: .cooked,
                massBasis: .cooked,
                sourceQuality: 1
            )
        )

        XCTAssertNil(result.autoPreselect)
        XCTAssertNil(result.mealEstimatorResolution.autoPreselect)
        XCTAssertTrue(result.requiresConfirmation)
    }

    private func entry(
        id: String,
        localFoodID: String,
        name: String,
        aliases: [String],
        preparation: FoodPreparation,
        edibleFraction: Double
    ) -> FoodCatalogEntry {
        FoodCatalogEntry(
            id: id,
            localFoodID: localFoodID,
            name: name,
            aliases: aliases,
            preparation: preparation,
            category: "fixture-food",
            edibleFraction: edibleFraction,
            nutrients: FoodNutrientProfile(energyKcalPer100Grams: 100),
            sourceVersion: "food-catalog-v2"
        )
    }
}
