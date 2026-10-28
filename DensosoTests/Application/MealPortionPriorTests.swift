import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class MealPortionPriorTests: XCTestCase {
    func testPersonalPriorIsAbsentWhilePendingAndSavedOnlyWithConfirmedMeal() async throws {
        let harness = try Harness()
        let priorRepository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let correction = try XCTUnwrap(MealPortionPriorCorrection(
            unit: "碗",
            unitCount: 1,
            totalGrams: 180
        ))
        let action = try await harness.coordinator.stage(
            payload: .meal(try Self.mealDraft(evidence: [correction.evidenceSnapshot])),
            clientRequestID: UUID()
        )

        let pendingPriors = try await priorRepository.all()
        XCTAssertTrue(pendingPriors.isEmpty)
        let pendingDishPriors = try await priorRepository.allDishPriors()
        XCTAssertTrue(pendingDishPriors.isEmpty)
        let receipt = try await harness.coordinator.confirm(action: action)
        let priors = try await priorRepository.all()
        XCTAssertEqual(priors.count, 1)
        XCTAssertEqual(priors.first?.foodName, "米饭")
        XCTAssertEqual(priors.first?.prior.unit, "bowl")
        XCTAssertEqual(try XCTUnwrap(priors.first).prior.p50Grams, 180, accuracy: 0.001)
        XCTAssertEqual(priors.first?.sourceActionKey, action.idempotencyKey)
        let englishUnitLookup = try await priorRepository.prior(
            foodID: "rice-id",
            foodName: "米饭",
            unit: "bowl"
        )
        XCTAssertEqual(try XCTUnwrap(englishUnitLookup).p50Grams, 180, accuracy: 0.001)

        let replay = try await harness.coordinator.confirm(action: action)
        XCTAssertEqual(replay.id, receipt.id)
        let replayedPriors = try await priorRepository.all()
        XCTAssertEqual(replayedPriors.count, 1)
    }

    func testModelPhotoAndRecipeOnlyMealGuessesNeverCreatePersonalPriors() async throws {
        let harness = try Harness()
        let priorRepository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let estimateEvidence = [
            EvidenceSnapshot(grade: .strong, sourceID: "portion:userReportedExact", summary: "model claimed exact grams"),
            EvidenceSnapshot(grade: .weak, sourceID: "portion:modelEstimate", summary: "model range"),
            EvidenceSnapshot(grade: .weak, sourceID: "portion:photoWithoutScale", summary: "photo range"),
            EvidenceSnapshot(grade: .moderate, sourceID: "recipe-prior:fixture:ingredient:rice", summary: "source recipe quantity"),
        ]
        for evidence in estimateEvidence {
            let action = try await harness.coordinator.stage(
                payload: .meal(try Self.mealDraft(evidence: [evidence])),
                clientRequestID: UUID()
            )
            _ = try await harness.coordinator.confirm(action: action)
        }

        let priors = try await priorRepository.all()
        XCTAssertTrue(priors.isEmpty)
        let unlearnedDishPriors = try await priorRepository.allDishPriors()
        XCTAssertTrue(unlearnedDishPriors.isEmpty)
    }

    func testDishPriorRequiresTwoExplicitUserPortionsUnlessManagedTemplate() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let userPortion = try XCTUnwrap(PersonalMealDishPriorUserPortionEvidence.evidenceSnapshot(grams: 85))

        let first = try await harness.coordinator.stage(
            payload: .meal(try Self.dishMealDraft(
                dishName: "番茄炒蛋",
                ingredientEvidence: [userPortion],
                dishEvidence: []
            )),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: first)

        let learnedOnce = try await repository.allDishPriors()
        XCTAssertEqual(learnedOnce.first?.observationCount, 1)
        let unavailablePrior = try await repository.dishPrior(named: "番茄炒蛋", cookingMethod: "stirFry")
        XCTAssertNil(unavailablePrior)

        let second = try await harness.coordinator.stage(
            payload: .meal(try Self.dishMealDraft(
                dishName: "番茄炒蛋",
                ingredientEvidence: [userPortion],
                dishEvidence: []
            )),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: second)

        let foundAvailable = try await repository.dishPrior(named: "番茄炒蛋", cookingMethod: "stirFry")
        let available = try XCTUnwrap(foundAvailable)
        XCTAssertEqual(available.observationCount, 2)
        XCTAssertFalse(available.isUserManaged)
        XCTAssertEqual(try XCTUnwrap(available.ingredients.first).likelyGrams, 85, accuracy: 0.001)

        let manualIngredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "tofu-id",
            name: "豆腐",
            lowGrams: 90,
            likelyGrams: 100,
            highGrams: 110
        ))
        try await repository.saveDishPrior(PersonalMealDishPriorEdit(
            id: nil,
            dishName: "豆腐汤",
            cookingMethod: "boil",
            ingredients: [manualIngredient]
        ))
        let foundManualTemplate = try await repository.dishPrior(named: "豆腐汤", cookingMethod: "boil")
        let manualTemplate = try XCTUnwrap(foundManualTemplate)
        XCTAssertTrue(manualTemplate.isUserManaged)
        XCTAssertEqual(manualTemplate.observationCount, 0)

        let ordinaryCorrection = try XCTUnwrap(
            PersonalMealDishPriorUserPortionEvidence.evidenceSnapshot(grams: 145)
        )
        let ordinaryConfirmation = try await harness.coordinator.stage(
            payload: .meal(try Self.dishMealDraft(
                dishName: "豆腐汤",
                cookingMethod: "boil",
                ingredientName: "豆腐",
                ingredientID: "tofu-id",
                ingredientEvidence: [ordinaryCorrection],
                dishEvidence: []
            )),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: ordinaryConfirmation)

        let foundPreservedTemplate = try await repository.dishPrior(named: "豆腐汤", cookingMethod: "boil")
        let preservedTemplate = try XCTUnwrap(foundPreservedTemplate)
        XCTAssertEqual(preservedTemplate.observationCount, 0)
        XCTAssertEqual(try XCTUnwrap(preservedTemplate.ingredients.first).likelyGrams, 100, accuracy: 0.001)
        try await repository.deleteDishPrior(id: preservedTemplate.id)
        let deletedTemplate = try await repository.dishPrior(named: "豆腐汤", cookingMethod: "boil")
        XCTAssertNil(deletedTemplate)
    }

    func testDishPriorKeepsMassBasisOnlyFromVerifiedFoodProvenance() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let userPortion = try XCTUnwrap(PersonalMealDishPriorUserPortionEvidence.evidenceSnapshot(grams: 85))
        let verifiedSource = EvidenceSnapshot(
            grade: .databaseMatch,
            sourceID: "food-composition:cn-food-table",
            sourceVersion: "cn-food-table-2026-01",
            summary: "sourceID=cn-food-table; sourceRecordID=tomato-001; licenseStatus=verified; massBasis=cooked; preparation=cooked"
        )
        let unverifiedSource = EvidenceSnapshot(
            grade: .databaseMatch,
            sourceID: "food-composition:unverified-source",
            sourceVersion: "unverified-table-v1",
            summary: "sourceID=unverified-source; sourceRecordID=tomato-002; licenseStatus=unverified; massBasis=cooked; preparation=cooked"
        )
        for (dishName, source) in [
            ("番茄炒蛋", verifiedSource),
            ("凉拌番茄", unverifiedSource),
        ] {
            let action = try await harness.coordinator.stage(
                payload: .meal(try Self.dishMealDraft(
                    dishName: dishName,
                    ingredientEvidence: [userPortion, source],
                    dishEvidence: []
                )),
                clientRequestID: UUID()
            )
            _ = try await harness.coordinator.confirm(action: action)
        }

        let priors = try await repository.allDishPriors()
        let verified = try XCTUnwrap(priors.first { $0.dishName == "番茄炒蛋" })
        let verifiedIngredient = try XCTUnwrap(verified.ingredients.first)
        XCTAssertEqual(verifiedIngredient.massBasis, .cooked)
        XCTAssertEqual(verifiedIngredient.sourceRecordID, "tomato-001")
        XCTAssertEqual(verifiedIngredient.licenseStatus, "verified")

        let unverified = try XCTUnwrap(priors.first { $0.dishName == "凉拌番茄" })
        let unverifiedIngredient = try XCTUnwrap(unverified.ingredients.first)
        XCTAssertNil(unverifiedIngredient.massBasis)
        XCTAssertNil(unverifiedIngredient.sourceRecordID)
    }

    func testMealCaptureCorrectionNeedsExplicitPortionSourceOrLabeledPackageServing() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        func correctedMarker(_ grams: Double) -> EvidenceSnapshot {
            EvidenceSnapshot(
                grade: .userReported,
                sourceID: "user-corrected-portion",
                sourceVersion: MealEstimator.algorithmVersion,
                summary: "\(grams)g",
                confidence: 1
            )
        }
        let modelOnlyCorrection = [
            correctedMarker(85),
            EvidenceSnapshot(
                grade: .weak,
                sourceID: "portion:modelEstimate",
                sourceVersion: PortionEstimator.algorithmVersion,
                summary: "model estimate"
            ),
        ]
        let explicitGramCorrection = [
            correctedMarker(85),
            EvidenceSnapshot(
                grade: .moderate,
                sourceID: "portion:userCorrection",
                sourceVersion: PortionEstimator.algorithmVersion,
                summary: "85g user correction"
            ),
        ]
        let packageWithoutLabel = [
            correctedMarker(85),
            EvidenceSnapshot(
                grade: .strong,
                sourceID: "portion:packageServing",
                sourceVersion: PortionEstimator.algorithmVersion,
                summary: "one package serving"
            ),
        ]
        let packageWithLabel = packageWithoutLabel + [
            EvidenceSnapshot(
                grade: .label,
                sourceID: "capture:nutritionLabel",
                sourceVersion: "nutrition-label-v1",
                summary: "每份 85 克"
            ),
        ]
        for evidence in [modelOnlyCorrection, packageWithoutLabel, explicitGramCorrection, packageWithLabel] {
            let action = try await harness.coordinator.stage(
                payload: .meal(try Self.mealDraft(evidence: evidence)),
                clientRequestID: UUID()
            )
            _ = try await harness.coordinator.confirm(action: action)
        }

        let priors = try await repository.allDishPriors()
        XCTAssertEqual(priors.count, 1)
        XCTAssertEqual(priors.first?.observationCount, 2)
    }

    func testPersistedDishPriorRejectsDecodedIngredientsThatFailDomainValidation() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let ingredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "tomato-id",
            name: "番茄",
            lowGrams: 70,
            likelyGrams: 85,
            highGrams: 100,
            massBasis: .cooked,
            sourceID: "food-table",
            sourceRecordID: "tomato-001",
            sourceVersion: "food-table-v1",
            licenseStatus: "verified"
        ))
        let encoder = JSONEncoder()
        let validData = try encoder.encode([ingredient])
        var invalidRange = try XCTUnwrap(try JSONSerialization.jsonObject(with: validData) as? [[String: Any]])
        invalidRange[0]["likelyGrams"] = 50
        var invalidBasis = try XCTUnwrap(try JSONSerialization.jsonObject(with: validData) as? [[String: Any]])
        invalidBasis[0]["licenseStatus"] = "unverified"
        let invalidRows = [
            ("番茄炒蛋", invalidRange),
            ("凉拌番茄", invalidBasis),
        ]
        let context = ModelContext(harness.container)
        for (dishName, row) in invalidRows {
            let key = try XCTUnwrap(MealDishPriorStorageKey.make(
                dishName: dishName,
                cookingMethod: "stirFry",
                ingredients: [ingredient]
            ))
            let encodedRow = try JSONSerialization.data(withJSONObject: row)
            let ingredientsJSON = try XCTUnwrap(String(data: encodedRow, encoding: .utf8))
            context.insert(PersonalMealDishPriorRecord(
                priorKey: key.priorKey,
                dishKey: key.dishKey,
                dishName: dishName,
                cookingMethodKey: key.cookingMethodKey,
                cookingMethod: "stirFry",
                ingredientsJSON: ingredientsJSON,
                observationCount: 2,
                isUserManaged: false,
                sourceActionKey: "invalid-import-fixture"
            ))
        }
        try context.save()

        let priors = try await repository.allDishPriors()
        XCTAssertTrue(priors.isEmpty)
        let unavailable = try await repository.dishPrior(named: "番茄炒蛋", cookingMethod: "stirFry")
        XCTAssertNil(unavailable)
    }

    func testSettingsRepositorySupportsExplicitCreateEditLookupAndDelete() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        try await repository.save(PersonalMealPortionPriorEdit(
            id: nil,
            foodName: "米饭",
            unit: "碗",
            gramsPerUnit: 175
        ))
        let initialPriors = try await repository.all()
        var prior = try XCTUnwrap(initialPriors.first)
        XCTAssertEqual(prior.prior.p50Grams, 175, accuracy: 0.001)
        let lookup = try await repository.prior(foodID: nil, foodName: "米饭", unit: "bowl")
        XCTAssertEqual(try XCTUnwrap(lookup).p50Grams, 175, accuracy: 0.001)

        try await repository.save(PersonalMealPortionPriorEdit(
            id: prior.id,
            foodName: "米饭",
            unit: "碗",
            gramsPerUnit: 190
        ))
        let editedPriors = try await repository.all()
        prior = try XCTUnwrap(editedPriors.first)
        XCTAssertEqual(prior.prior.p50Grams, 190, accuracy: 0.001)
        try await repository.delete(id: prior.id)
        let remainingPriors = try await repository.all()
        XCTAssertTrue(remainingPriors.isEmpty)
    }

    private static func mealDraft(evidence: [EvidenceSnapshot]) throws -> MealDraft {
        let portion = try EstimateRange(low: 160, likely: 180, high: 200)
        let macros = try EstimateRange.point(20)
        let ingredient = MealIngredientDraft(
            foodID: "rice-id",
            name: "米饭",
            amountGrams: portion,
            nutrients: NutrientEstimate(
                energyKcal: try EstimateRange(low: 190, likely: 210, high: 230),
                proteinGrams: macros,
                fatGrams: macros,
                carbohydrateGrams: macros
            ),
            evidence: evidence
        )
        let dish = MealDishDraft(
            name: "米饭",
            portionGrams: portion,
            nutrients: NutrientEstimate(
                energyKcal: try EstimateRange(low: 190, likely: 210, high: 230),
                proteinGrams: macros,
                fatGrams: macros,
                carbohydrateGrams: macros
            ),
            ingredients: [ingredient],
            evidence: evidence,
            algorithmVersion: MealEstimator.algorithmVersion
        )
        return MealDraft(
            occurredAt: Date(timeIntervalSince1970: 1_750_000_000),
            mealType: "lunch",
            dishes: [dish]
        )
    }

    private static func dishMealDraft(
        dishName: String,
        cookingMethod: String = "stirFry",
        ingredientName: String = "番茄",
        ingredientID: String = "tomato-id",
        ingredientEvidence: [EvidenceSnapshot],
        dishEvidence: [EvidenceSnapshot]
    ) throws -> MealDraft {
        let portion = try EstimateRange(low: 75, likely: 85, high: 95)
        let macros = try EstimateRange.point(12)
        let ingredient = MealIngredientDraft(
            foodID: ingredientID,
            name: ingredientName,
            amountGrams: portion,
            nutrients: NutrientEstimate(
                energyKcal: try EstimateRange(low: 12, likely: 16, high: 20),
                proteinGrams: macros,
                fatGrams: macros,
                carbohydrateGrams: macros
            ),
            evidence: ingredientEvidence
        )
        let dish = MealDishDraft(
            name: dishName,
            cookingMethod: cookingMethod,
            portionGrams: portion,
            nutrients: NutrientEstimate(
                energyKcal: try EstimateRange(low: 12, likely: 16, high: 20),
                proteinGrams: macros,
                fatGrams: macros,
                carbohydrateGrams: macros
            ),
            ingredients: [ingredient],
            evidence: dishEvidence,
            algorithmVersion: MealEstimator.algorithmVersion
        )
        return MealDraft(
            occurredAt: Date(timeIntervalSince1970: 1_750_000_000),
            mealType: "lunch",
            dishes: [dish]
        )
    }
}

@MainActor
private struct Harness {
    let container: ModelContainer
    let coordinator: ConfirmationCoordinator

    init() throws {
        let schema = Schema(versionedSchema: DensosoSchemaV12.self)
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        coordinator = ConfirmationCoordinator(
            repository: SwiftDataConfirmationRepository(modelContainer: container),
            writeGate: PersistenceWriteGate(state: .writable),
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
    }
}
