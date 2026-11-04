import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class MealPriorSchemaMigrationTests: XCTestCase {
    func testV13MigrationPreservesLegacyPriorsAndAppliesNewContributionsAfterReopen() async throws {
        let location = try MealPriorMigrationStoreLocation()
        defer { location.remove() }

        var sourceContainer: ModelContainer?
        var sourceContext: ModelContext?
        var migratedContainer: ModelContainer?
        var currentContainer: ModelContainer?
        var repository: SwiftDataMealPortionPriorRepository?
        var updatedRepository: SwiftDataMealPortionPriorRepository?
        defer {
            updatedRepository = nil
            repository = nil
            currentContainer = nil
            migratedContainer = nil
            sourceContext = nil
            sourceContainer = nil
        }

        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let sourceSchema = Schema(versionedSchema: DensosoSchemaV13.self)
        let sourceConfiguration = ModelConfiguration("Densoso", schema: sourceSchema, url: location.storeURL)
        sourceContainer = try ModelContainer(
            for: sourceSchema,
            configurations: [sourceConfiguration]
        )
        sourceContext = ModelContext(sourceContainer!)

        let portionKey = try XCTUnwrap(
            MealPortionPriorStorageKey.make(foodID: "rice-id", foodName: "米饭", unit: "碗")
        )
        let oldPortionSourceActionKey = "v13-legacy-rice-meal"
        sourceContext?.insert(MealRecord(
            date: createdAt,
            totalCaloriesKcal: 300,
            sourceActionKey: oldPortionSourceActionKey
        ))
        sourceContext?.insert(DensosoSchemaV10.PersonalMealPortionPriorRecord(
            priorKey: portionKey,
            foodID: "rice-id",
            foodName: "米饭",
            unit: "bowl",
            p10Grams: 160,
            p50Grams: 180,
            p90Grams: 200,
            sourceActionKey: oldPortionSourceActionKey,
            createdAt: createdAt,
            updatedAt: createdAt
        ))

        let learnedDishIngredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "tomato-id",
            name: "番茄",
            lowGrams: 90,
            likelyGrams: 100,
            highGrams: 110
        ))
        let learnedDishKey = try XCTUnwrap(MealDishPriorStorageKey.make(
            dishName: "番茄炒蛋",
            cookingMethod: "stirFry",
            ingredients: [learnedDishIngredient]
        ))
        let legacyDishSourceActionKey = "v13-legacy-tomato-egg-meal"
        sourceContext?.insert(DensosoSchemaV12.PersonalMealDishPriorRecord(
            priorKey: learnedDishKey.priorKey,
            dishKey: learnedDishKey.dishKey,
            dishName: "番茄炒蛋",
            cookingMethodKey: learnedDishKey.cookingMethodKey,
            cookingMethod: "stirFry",
            ingredientsJSON: try Self.encode([learnedDishIngredient]),
            observationCount: 2,
            isUserManaged: false,
            sourceActionKey: legacyDishSourceActionKey,
            createdAt: createdAt,
            updatedAt: createdAt
        ))
        sourceContext?.insert(MealRecord(
            date: createdAt.addingTimeInterval(60),
            totalCaloriesKcal: 250,
            sourceActionKey: legacyDishSourceActionKey
        ))

        let managedDishIngredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "tofu-id",
            name: "豆腐",
            lowGrams: 120,
            likelyGrams: 130,
            highGrams: 140
        ))
        let managedDishKey = try XCTUnwrap(MealDishPriorStorageKey.make(
            dishName: "家常豆腐",
            cookingMethod: "stirFry",
            ingredients: [managedDishIngredient]
        ))
        sourceContext?.insert(DensosoSchemaV12.PersonalMealDishPriorRecord(
            priorKey: managedDishKey.priorKey,
            dishKey: managedDishKey.dishKey,
            dishName: "家常豆腐",
            cookingMethodKey: managedDishKey.cookingMethodKey,
            cookingMethod: "stirFry",
            ingredientsJSON: try Self.encode([managedDishIngredient]),
            observationCount: 0,
            isUserManaged: true,
            sourceActionKey: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        ))

        try sourceContext?.save()
        sourceContext = nil
        sourceContainer = nil
        await Task.yield()
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "13.0.0")

        migratedContainer = try Self.openCurrentStore(at: location.storeURL)
        XCTAssertNotNil(migratedContainer)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "14.0.0")
        migratedContainer = nil
        await Task.yield()

        // Reopen the migrated on-disk V14 store before checking prior reads or
        // applying new confirmation contributions.
        currentContainer = try Self.openCurrentStore(at: location.storeURL)
        repository = SwiftDataMealPortionPriorRepository(
            modelContainer: currentContainer!
        )
        let legacyPortion = try await repository!.prior(foodID: "rice-id", foodName: "米饭", unit: "碗")
        XCTAssertEqual(try XCTUnwrap(legacyPortion).p50Grams, 180, accuracy: 0.001)
        let legacyLearnedDish = try await repository!.dishPrior(named: "番茄炒蛋", cookingMethod: "stirFry")
        XCTAssertEqual(try XCTUnwrap(legacyLearnedDish).observationCount, 2)
        XCTAssertEqual(try XCTUnwrap(legacyLearnedDish?.ingredients.first).likelyGrams, 100, accuracy: 0.001)
        let managedDish = try await repository!.dishPrior(named: "家常豆腐", cookingMethod: "stirFry")
        XCTAssertTrue(try XCTUnwrap(managedDish).isUserManaged)
        XCTAssertEqual(try XCTUnwrap(managedDish?.ingredients.first).likelyGrams, 130, accuracy: 0.001)
        XCTAssertEqual(
            try currentContainer!.mainContext.fetchCount(FetchDescriptor<MealPriorContributionRecord>()),
            0
        )

        let newSourceActionKey = "v14-confirmed-rice-and-tomato-egg-meal"
        let now = createdAt.addingTimeInterval(3_600)
        let portionCorrection = try XCTUnwrap(MealPortionPriorCorrection(unit: "碗", totalGrams: 240))
        let riceIngredient = MealIngredientDraft(
            foodID: "rice-id",
            name: "米饭",
            amountGrams: try EstimateRange.point(240),
            nutrients: NutrientEstimate(energyKcal: try EstimateRange.point(300)),
            evidence: [portionCorrection.evidenceSnapshot]
        )
        let tomatoPortionEvidence = try XCTUnwrap(
            PersonalMealDishPriorUserPortionEvidence.evidenceSnapshot(grams: 160)
        )
        let tomatoIngredient = MealIngredientDraft(
            foodID: "tomato-id",
            name: "番茄",
            amountGrams: try EstimateRange.point(160),
            nutrients: NutrientEstimate(energyKcal: try EstimateRange.point(80)),
            evidence: [tomatoPortionEvidence]
        )
        let tomatoEggDish = MealDishDraft(
            name: "番茄炒蛋",
            cookingMethod: "stirFry",
            portionGrams: try EstimateRange.point(160),
            nutrients: NutrientEstimate(energyKcal: try EstimateRange.point(250)),
            ingredients: [tomatoIngredient],
            algorithmVersion: MealEstimator.algorithmVersion
        )
        currentContainer!.mainContext.insert(MealRecord(
            date: now,
            totalCaloriesKcal: 550,
            sourceActionKey: newSourceActionKey
        ))
        try SwiftDataMealPortionPriorRepository.recordConfirmedCorrections(
            in: currentContainer!.mainContext,
            ingredients: [riceIngredient],
            sourceActionKey: newSourceActionKey,
            now: now
        )
        try SwiftDataMealPortionPriorRepository.recordConfirmedDishes(
            in: currentContainer!.mainContext,
            dishes: [tomatoEggDish],
            sourceActionKey: newSourceActionKey,
            now: now
        )
        try currentContainer!.mainContext.save()

        // Close every V14 handle, then reopen the disk store once more. This
        // proves the newly written contribution ledger and recomputed priors
        // survive a process-style container replacement.
        repository = nil
        currentContainer = nil
        await Task.yield()
        currentContainer = try Self.openCurrentStore(at: location.storeURL)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "14.0.0")
        updatedRepository = SwiftDataMealPortionPriorRepository(
            modelContainer: currentContainer!
        )
        let appliedPortion = try await updatedRepository!.prior(foodID: "rice-id", foodName: "米饭", unit: "碗")
        XCTAssertEqual(try XCTUnwrap(appliedPortion).p50Grams, 210, accuracy: 0.001)
        let appliedLearnedDish = try await updatedRepository!.dishPrior(named: "番茄炒蛋", cookingMethod: "stirFry")
        XCTAssertEqual(try XCTUnwrap(appliedLearnedDish).observationCount, 3)
        XCTAssertEqual(try XCTUnwrap(appliedLearnedDish?.ingredients.first).likelyGrams, 120, accuracy: 0.001)
        let preservedManagedDish = try await updatedRepository!.dishPrior(named: "家常豆腐", cookingMethod: "stirFry")
        XCTAssertTrue(try XCTUnwrap(preservedManagedDish).isUserManaged)
        XCTAssertEqual(try XCTUnwrap(preservedManagedDish?.ingredients.first).likelyGrams, 130, accuracy: 0.001)

        // Keep only scalar counts from fetched SwiftData models so no model
        // objects retain the context while the disk container is released.
        var contributionCounts: [String: Int] = [:]
        for contribution in try currentContainer!.mainContext.fetch(FetchDescriptor<MealPriorContributionRecord>()) {
            contributionCounts["total", default: 0] += 1
            contributionCounts[contribution.kindRaw, default: 0] += 1
            if contribution.isLegacyAggregate {
                contributionCounts["legacy", default: 0] += 1
                contributionCounts["legacy-\(contribution.kindRaw)", default: 0] += 1
            } else if contribution.sourceActionKey == newSourceActionKey {
                contributionCounts["new", default: 0] += 1
                contributionCounts["new-\(contribution.kindRaw)", default: 0] += 1
            }
        }
        XCTAssertEqual(contributionCounts["total"], 4)
        XCTAssertEqual(contributionCounts[MealPriorContributionKind.portion.rawValue], 2)
        XCTAssertEqual(contributionCounts[MealPriorContributionKind.dish.rawValue], 2)
        XCTAssertEqual(contributionCounts["legacy"], 2)
        XCTAssertEqual(contributionCounts["legacy-\(MealPriorContributionKind.portion.rawValue)"], 1)
        XCTAssertEqual(contributionCounts["legacy-\(MealPriorContributionKind.dish.rawValue)"], 1)
        XCTAssertEqual(contributionCounts["new"], 2)
        XCTAssertEqual(contributionCounts["new-\(MealPriorContributionKind.portion.rawValue)"], 1)
        XCTAssertEqual(contributionCounts["new-\(MealPriorContributionKind.dish.rawValue)"], 1)

        updatedRepository = nil
        currentContainer = nil
        await Task.yield()
    }

    private static func openCurrentStore(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        return try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private static func encode(_ ingredients: [PersonalMealDishIngredientPrior]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(ingredients), as: UTF8.self)
    }
}

private struct MealPriorMigrationStoreLocation {
    let directoryURL: URL
    let storeURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-meal-prior-v13-v14-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        storeURL = directoryURL.appendingPathComponent("default.store")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
