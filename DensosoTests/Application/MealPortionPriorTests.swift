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
        let receipt = try await harness.coordinator.confirm(id: action.id)
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

        let replay = try await harness.coordinator.confirm(id: action.id)
        XCTAssertEqual(replay.id, receipt.id)
        let replayedPriors = try await priorRepository.all()
        XCTAssertEqual(replayedPriors.count, 1)
    }

    func testModelOnlyMealGuessNeverCreatesPersonalPrior() async throws {
        let harness = try Harness()
        let priorRepository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let action = try await harness.coordinator.stage(
            payload: .meal(try Self.mealDraft(evidence: [
                EvidenceSnapshot(grade: .estimated, sourceID: "portion:household", summary: "bowl estimate")
            ])),
            clientRequestID: UUID()
        )

        _ = try await harness.coordinator.confirm(id: action.id)
        let priors = try await priorRepository.all()
        XCTAssertTrue(priors.isEmpty)
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
}

@MainActor
private struct Harness {
    let container: ModelContainer
    let coordinator: ConfirmationCoordinator

    init() throws {
        let schema = Schema(versionedSchema: DensosoSchemaV10.self)
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
