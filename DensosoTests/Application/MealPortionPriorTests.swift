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

    func testDeletingMealRemovesOnlyItsLearnedPortionContribution() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let correction = try XCTUnwrap(MealPortionPriorCorrection(unit: "碗", unitCount: 1, totalGrams: 180))
        let action = try await harness.coordinator.stage(
            payload: .meal(try Self.mealDraft(evidence: [correction.evidenceSnapshot])),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: action)

        let storedMeal = try XCTUnwrap(ModelContext(harness.container)
            .fetch(FetchDescriptor<MealRecord>()).first { $0.sourceActionKey == action.idempotencyKey })
        let contributions = try ModelContext(harness.container).fetch(FetchDescriptor<MealPriorContributionRecord>())
        XCTAssertEqual(
            contributions.filter { $0.kindRaw == MealPriorContributionKind.portion.rawValue }.count,
            1
        )
        XCTAssertEqual(
            contributions.filter { $0.kindRaw == MealPriorContributionKind.dish.rawValue }.count,
            1
        )
        try await HealthRepository(modelContext: ModelContext(harness.container)).deleteMeal(id: storedMeal.id)

        let remainingPriors = try await repository.all()
        XCTAssertTrue(remainingPriors.isEmpty)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealPriorContributionRecord>()), 0)
    }

    func testDeletingLearnedPriorsClearsOnlyMatchingContributionLedgerAndPreventsResurrection() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let correction = try XCTUnwrap(MealPortionPriorCorrection(unit: "碗", unitCount: 1, totalGrams: 180))
        var riceActions: [PendingAction] = []
        for (foodID, foodName) in [("rice-id", "米饭"), ("rice-id", "米饭"), ("oats-id", "燕麦")] {
            let action = try await harness.coordinator.stage(
                payload: .meal(try Self.mealDraft(
                    evidence: [correction.evidenceSnapshot],
                    foodName: foodName,
                    foodID: foodID
                )),
                clientRequestID: UUID()
            )
            _ = try await harness.coordinator.confirm(action: action)
            if foodID == "rice-id" { riceActions.append(action) }
        }

        let initialPortions = try await repository.all()
        let initialDishPriors = try await repository.allDishPriors()
        let ricePortion = try XCTUnwrap(initialPortions.first { $0.foodName == "米饭" })
        let riceDish = try XCTUnwrap(initialDishPriors.first { $0.dishName == "米饭" })
        let oatsPortion = try XCTUnwrap(initialPortions.first { $0.foodName == "燕麦" })
        let oatsDish = try XCTUnwrap(initialDishPriors.first { $0.dishName == "燕麦" })
        try await repository.save(PersonalMealPortionPriorEdit(
            id: nil,
            foodID: "manual-id",
            foodName: "手动管理",
            unit: "碗",
            gramsPerUnit: 130
        ))
        let portionsAfterManualCreate = try await repository.all()
        let userManagedPortion = try XCTUnwrap(portionsAfterManualCreate.first { $0.foodName == "手动管理" })

        try await repository.delete(id: ricePortion.id)
        var contributions = try ModelContext(harness.container).fetch(FetchDescriptor<MealPriorContributionRecord>())
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.portion.rawValue && $0.priorKey == ricePortion.priorKey
        }.count, 0)
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.dish.rawValue && $0.priorKey == riceDish.priorKey
        }.count, 2)
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.portion.rawValue && $0.priorKey == oatsPortion.priorKey
        }.count, 1)
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.dish.rawValue && $0.priorKey == oatsDish.priorKey
        }.count, 1)

        try await repository.deleteDishPrior(id: riceDish.id)
        contributions = try ModelContext(harness.container).fetch(FetchDescriptor<MealPriorContributionRecord>())
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.dish.rawValue && $0.priorKey == riceDish.priorKey
        }.count, 0)
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.portion.rawValue && $0.priorKey == oatsPortion.priorKey
        }.count, 1)
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.dish.rawValue && $0.priorKey == oatsDish.priorKey
        }.count, 1)
        let portionsAfterPriorDeletes = try await repository.all()
        XCTAssertTrue(portionsAfterPriorDeletes.contains { $0.id == userManagedPortion.id })

        let mealContext = ModelContext(harness.container)
        let riceMealIDs = try mealContext.fetch(FetchDescriptor<MealRecord>())
            .filter { meal in riceActions.contains { $0.idempotencyKey == meal.sourceActionKey } }
            .map(\.id)
        for mealID in riceMealIDs {
            try await HealthRepository(modelContext: ModelContext(harness.container)).deleteMeal(id: mealID)
        }

        let finalPortions = try await repository.all()
        let finalDishPriors = try await repository.allDishPriors()
        XCTAssertFalse(finalPortions.contains { $0.priorKey == ricePortion.priorKey })
        XCTAssertFalse(finalDishPriors.contains { $0.priorKey == riceDish.priorKey })
        XCTAssertTrue(finalPortions.contains { $0.priorKey == oatsPortion.priorKey })
        XCTAssertTrue(finalDishPriors.contains { $0.priorKey == oatsDish.priorKey })
        XCTAssertTrue(finalPortions.contains { $0.id == userManagedPortion.id })
    }

    func testManualPriorEditWaitsForConfirmationStoreLease() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let correction = try XCTUnwrap(MealPortionPriorCorrection(unit: "碗", unitCount: 1, totalGrams: 180))
        let initialAction = try await harness.coordinator.stage(
            payload: .meal(try Self.mealDraft(evidence: [correction.evidenceSnapshot])),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: initialAction)
        let initialPriors = try await repository.all()
        let learned = try XCTUnwrap(initialPriors.first { $0.foodName == "米饭" })
        let concurrentAction = try await harness.coordinator.stage(
            payload: .meal(try Self.mealDraft(evidence: [correction.evidenceSnapshot])),
            clientRequestID: UUID()
        )
        let confirmationDay = DailyMetricsProjectionWriteGate.dayKey(
            for: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let owner = try await DailyMetricsProjectionWriteGate.acquire(
            for: harness.container,
            dayKeys: [confirmationDay]
        )
        let confirmation = Task { try await harness.coordinator.confirm(action: concurrentAction) }
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(
            1,
            storeID: ObjectIdentifier(harness.container)
        )
        let manualEdit = Task {
            try await repository.save(PersonalMealPortionPriorEdit(
                id: learned.id,
                foodID: "rice-id",
                foodName: "米饭",
                unit: "碗",
                gramsPerUnit: 120
            ))
        }
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(
            2,
            storeID: ObjectIdentifier(harness.container)
        )

        DailyMetricsProjectionWriteGate.release(owner)
        _ = try await confirmation.value
        try await manualEdit.value

        let savedPortions = try await repository.all()
        let saved = try XCTUnwrap(savedPortions.first { $0.foodName == "米饭" })
        XCTAssertEqual(saved.prior.p50Grams, 120, accuracy: 0.001)
        let contributions = try ModelContext(harness.container).fetch(FetchDescriptor<MealPriorContributionRecord>())
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.portion.rawValue && $0.priorKey == saved.priorKey
        }.count, 0)

        try await repository.save(PersonalMealPortionPriorEdit(
            id: saved.id,
            foodName: "糙米",
            unit: "碗",
            gramsPerUnit: 125
        ))
        let renamedPriors = try await repository.all()
        XCTAssertTrue(renamedPriors.contains { $0.id == saved.id && $0.foodName == "糙米" })
        XCTAssertFalse(renamedPriors.contains { $0.priorKey == saved.priorKey })

        let mealIDs = try ModelContext(harness.container).fetch(FetchDescriptor<MealRecord>())
            .filter { meal in
                [initialAction.idempotencyKey, concurrentAction.idempotencyKey].contains(meal.sourceActionKey)
            }
            .map(\.id)
        for mealID in mealIDs {
            try await HealthRepository(modelContext: ModelContext(harness.container)).deleteMeal(id: mealID)
        }
        let afterOriginMealDeletion = try await repository.all()
        XCTAssertTrue(afterOriginMealDeletion.contains { $0.id == saved.id && $0.foodName == "糙米" })
        XCTAssertFalse(afterOriginMealDeletion.contains { $0.priorKey == saved.priorKey })
    }

    func testPriorSaveAndDeleteFailuresRollbackRowsAndContributionLedger() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let failedCreateEdit = PersonalMealPortionPriorEdit(
            id: nil,
            foodID: "failed-id",
            foodName: "失败写入",
            unit: "碗",
            gramsPerUnit: 125
        )
        await repository.failNextSaveForTesting()
        do {
            try await repository.save(failedCreateEdit)
            XCTFail("Injected save failure should be rethrown")
        } catch MealPortionPriorInjectedFailure.beforeSave {
            // Expected: the pending insertion must be rolled back.
        }
        let afterFailedCreate = try await repository.all()
        XCTAssertFalse(afterFailedCreate.contains { $0.foodName == "失败写入" })
        try await repository.save(failedCreateEdit)
        let afterSuccessfulRetry = try await repository.all()
        let retriedPrior = try XCTUnwrap(afterSuccessfulRetry.first { $0.foodName == "失败写入" })
        XCTAssertEqual(afterSuccessfulRetry.filter { $0.foodName == "失败写入" }.count, 1)
        XCTAssertEqual(retriedPrior.prior.p50Grams, 125, accuracy: 0.001)

        let correction = try XCTUnwrap(MealPortionPriorCorrection(unit: "碗", unitCount: 1, totalGrams: 180))
        let action = try await harness.coordinator.stage(
            payload: .meal(try Self.mealDraft(evidence: [correction.evidenceSnapshot])),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: action)
        let learnedPortions = try await repository.all()
        let learned = try XCTUnwrap(learnedPortions.first { $0.foodName == "米饭" })
        await repository.failNextSaveForTesting()
        do {
            try await repository.delete(id: learned.id)
            XCTFail("Injected save failure should be rethrown")
        } catch MealPortionPriorInjectedFailure.beforeSave {
            // Expected: both the row and its contribution must survive rollback.
        }

        let afterFailedDelete = try await repository.all()
        XCTAssertTrue(afterFailedDelete.contains { $0.id == learned.id })
        let contributions = try ModelContext(harness.container).fetch(FetchDescriptor<MealPriorContributionRecord>())
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.portion.rawValue && $0.priorKey == learned.priorKey
        }.count, 1)
    }

    func testDishTemplateEditWaitsForConfirmationStoreLease() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let manualIngredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "template-egg-id",
            name: "鸡蛋",
            lowGrams: 90,
            likelyGrams: 100,
            highGrams: 110
        ))
        try await repository.saveDishPrior(PersonalMealDishPriorEdit(
            id: nil,
            dishName: "番茄炒蛋",
            cookingMethod: "steam",
            ingredients: [manualIngredient]
        ))
        let initialPriors = try await repository.allDishPriors()
        let manualTemplate = try XCTUnwrap(initialPriors.first { $0.ingredients.first?.foodID == "template-egg-id" })

        let explicitPortion = try XCTUnwrap(PersonalMealDishPriorUserPortionEvidence.evidenceSnapshot(grams: 85))
        let firstAction = try await harness.coordinator.stage(
            payload: .meal(try Self.dishMealDraft(
                dishName: "番茄炒蛋",
                cookingMethod: "stirFry",
                ingredientName: "番茄",
                ingredientID: "tomato-id",
                ingredientEvidence: [explicitPortion],
                dishEvidence: []
            )),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: firstAction)
        let learnedPriors = try await repository.allDishPriors()
        let learnedDish = try XCTUnwrap(learnedPriors.first { $0.ingredients.first?.foodID == "tomato-id" })

        let concurrentAction = try await harness.coordinator.stage(
            payload: .meal(try Self.dishMealDraft(
                dishName: "番茄炒蛋",
                cookingMethod: "stirFry",
                ingredientName: "番茄",
                ingredientID: "tomato-id",
                ingredientEvidence: [explicitPortion],
                dishEvidence: []
            )),
            clientRequestID: UUID()
        )
        let confirmationDay = DailyMetricsProjectionWriteGate.dayKey(
            for: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let owner = try await DailyMetricsProjectionWriteGate.acquire(
            for: harness.container,
            dayKeys: [confirmationDay]
        )
        let confirmation = Task { try await harness.coordinator.confirm(action: concurrentAction) }
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(
            1,
            storeID: ObjectIdentifier(harness.container)
        )
        let updatedManualIngredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "template-egg-id",
            name: "鸡蛋",
            lowGrams: 125,
            likelyGrams: 130,
            highGrams: 135
        ))
        let manualEdit = Task {
            try await repository.saveDishPrior(PersonalMealDishPriorEdit(
                id: manualTemplate.id,
                dishName: "番茄炒蛋",
                cookingMethod: "stirFry",
                ingredients: [updatedManualIngredient]
            ))
        }
        await DailyMetricsProjectionWriteGate.waitUntilWaitingCount(
            2,
            storeID: ObjectIdentifier(harness.container)
        )

        DailyMetricsProjectionWriteGate.release(owner)
        _ = try await confirmation.value
        try await manualEdit.value

        let finalPriors = try await repository.allDishPriors()
        let finalManualTemplate = try XCTUnwrap(finalPriors.first { $0.id == manualTemplate.id })
        XCTAssertTrue(finalManualTemplate.isUserManaged)
        XCTAssertEqual(try XCTUnwrap(finalManualTemplate.ingredients.first).likelyGrams, 130, accuracy: 0.001)
        let finalLearnedDish = try XCTUnwrap(finalPriors.first { $0.id == learnedDish.id })
        XCTAssertEqual(finalLearnedDish.observationCount, 2)
        let contributions = try ModelContext(harness.container).fetch(FetchDescriptor<MealPriorContributionRecord>())
        XCTAssertEqual(contributions.filter {
            $0.kindRaw == MealPriorContributionKind.dish.rawValue && $0.priorKey == learnedDish.priorKey
        }.count, 2)
        XCTAssertFalse(contributions.contains { $0.kindRaw == MealPriorContributionKind.dish.rawValue
            && $0.priorKey == finalManualTemplate.priorKey })

        let mealIDs = try ModelContext(harness.container).fetch(FetchDescriptor<MealRecord>())
            .filter { meal in
                [firstAction.idempotencyKey, concurrentAction.idempotencyKey].contains(meal.sourceActionKey)
            }
            .map(\.id)
        for mealID in mealIDs {
            try await HealthRepository(modelContext: ModelContext(harness.container)).deleteMeal(id: mealID)
        }
        let afterOriginMealDeletion = try await repository.allDishPriors()
        XCTAssertTrue(afterOriginMealDeletion.contains { $0.id == finalManualTemplate.id })
        XCTAssertFalse(afterOriginMealDeletion.contains { $0.id == learnedDish.id })
    }

    func testDishPriorSaveFailureRollsBackAndNextSaveOnSameActorIsClean() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let ingredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "soup-tofu-id",
            name: "豆腐",
            lowGrams: 90,
            likelyGrams: 100,
            highGrams: 110
        ))
        let edit = PersonalMealDishPriorEdit(
            id: nil,
            dishName: "豆腐汤",
            cookingMethod: "boil",
            ingredients: [ingredient]
        )
        await repository.failNextSaveForTesting()
        do {
            try await repository.saveDishPrior(edit)
            XCTFail("Injected save failure should be rethrown")
        } catch MealPortionPriorInjectedFailure.beforeSave {
            // Expected: the pending insertion must be rolled back.
        }
        let afterFailure = try await repository.allDishPriors()
        XCTAssertTrue(afterFailure.isEmpty)

        try await repository.saveDishPrior(edit)
        let savedPriors = try await repository.allDishPriors()
        XCTAssertEqual(savedPriors.count, 1)
        let saved = try XCTUnwrap(savedPriors.first)
        XCTAssertTrue(saved.isUserManaged)
        XCTAssertEqual(saved.observationCount, 0)
        XCTAssertEqual(saved.ingredients, [ingredient])
    }

    func testDeletingOriginMealPreservesUserManagedDishPrior() async throws {
        let harness = try Harness()
        let repository = SwiftDataMealPortionPriorRepository(modelContainer: harness.container)
        let optIn = try XCTUnwrap(PersonalMealDishPriorTemplateOptIn.evidenceSnapshot(dishName: "家常豆腐"))
        let userPortion = try XCTUnwrap(PersonalMealDishPriorUserPortionEvidence.evidenceSnapshot(grams: 120))
        let action = try await harness.coordinator.stage(
            payload: .meal(try Self.dishMealDraft(
                dishName: "家常豆腐",
                ingredientName: "豆腐",
                ingredientID: "tofu-id",
                ingredientEvidence: [userPortion],
                dishEvidence: [optIn]
            )),
            clientRequestID: UUID()
        )
        _ = try await harness.coordinator.confirm(action: action)
        let meal = try XCTUnwrap(ModelContext(harness.container)
            .fetch(FetchDescriptor<MealRecord>()).first { $0.sourceActionKey == action.idempotencyKey })
        try await HealthRepository(modelContext: ModelContext(harness.container)).deleteMeal(id: meal.id)

        let preserved = try await repository.dishPrior(named: "家常豆腐", cookingMethod: "stirFry")
        XCTAssertTrue(try XCTUnwrap(preserved).isUserManaged)
        XCTAssertEqual(try XCTUnwrap(preserved?.ingredients.first).likelyGrams, 120, accuracy: 0.001)
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

    private static func mealDraft(
        evidence: [EvidenceSnapshot],
        foodName: String = "米饭",
        foodID: String = "rice-id"
    ) throws -> MealDraft {
        let portion = try EstimateRange(low: 160, likely: 180, high: 200)
        let macros = try EstimateRange.point(20)
        let ingredient = MealIngredientDraft(
            foodID: foodID,
            name: foodName,
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
            name: foodName,
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
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
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
