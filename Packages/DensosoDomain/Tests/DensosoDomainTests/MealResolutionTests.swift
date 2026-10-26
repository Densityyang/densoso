import Dispatch
import Foundation
import XCTest
@testable import DensosoDomain

final class MealResolutionTests: XCTestCase {
    func testResolverKeepsRawAndCookedRiceSeparate() {
        let resolver = FoodResolver(catalog: fixtureCatalog())

        let cooked = resolver.resolve(
            FoodResolutionQuery(label: "白米饭", preparation: .cooked, sourceQuality: 1)
        )
        let raw = resolver.resolve(
            FoodResolutionQuery(label: "大米", preparation: .raw, sourceQuality: 1)
        )

        XCTAssertEqual(cooked.candidates.first?.id, "rice-cooked")
        XCTAssertEqual(raw.candidates.first?.id, "rice-raw")
        XCTAssertNotEqual(cooked.candidates.first?.id, raw.candidates.first?.id)
        XCTAssertTrue(cooked.requiresConfirmation)
    }

    func testAmbiguousCandidateNeverGetsFoodIDUntilThresholdOrSelection() throws {
        let resolver = FoodResolver(catalog: fixtureCatalog())
        let resolution = resolver.resolve(
            FoodResolutionQuery(label: "米", preparation: .unknown, sourceQuality: 0.5)
        )
        let portion = try PortionEstimator().estimate(
            evidence: [.photo(likelyGrams: 180, hasScale: false, isMixedDish: false, isOccluded: false, unknownContainer: false)],
            food: resolution.candidates.first
        )

        let dish = try MealEstimator().estimateDish(
            MealDishEstimationInput(
                name: "米",
                ingredients: [
                    MealIngredientEstimationInput(
                        label: "米",
                        resolution: resolution,
                        portion: portion,
                        massBasis: .cooked
                    )
                ]
            )
        )

        XCTAssertNil(resolution.autoPreselect)
        XCTAssertNil(dish.ingredients.first?.foodID)
        XCTAssertEqual(resolution.candidates.count, 2)
    }

    func testPortionRulesAndSinglePhotoNeverMeasured() throws {
        let estimator = PortionEstimator()
        let approximate = try estimator.estimate(evidence: [.approximateGrams(grams: 200)], food: nil)
        XCTAssertEqual(approximate.lowGrams, 180, accuracy: 0.001)
        XCTAssertEqual(approximate.highGrams, 220, accuracy: 0.001)

        let photo = try estimator.estimate(
            evidence: [.photo(likelyGrams: 200, hasScale: false, isMixedDish: true, isOccluded: false, unknownContainer: false)],
            food: nil
        )
        XCTAssertFalse(photo.isMeasured)
        XCTAssertLessThanOrEqual(photo.lowGrams, 70)
        XCTAssertGreaterThanOrEqual(photo.highGrams, 330)
    }

    func testMealEstimatorDoesNotDuplicateOilForCookedComposite() throws {
        let entry = FoodCatalogEntry(
            id: "braised-tofu",
            name: "红烧豆腐",
            aliases: [],
            preparation: .cooked,
            category: "preparedDish",
            nutrients: FoodNutrientProfile(
                energyKcalPer100Grams: 150,
                proteinGramsPer100Grams: 8,
                fatGramsPer100Grams: 10,
                carbohydrateGramsPer100Grams: 5
            ),
            isCookedComposite: true,
            sourceVersion: "fixture"
        )
        let resolution = selected(entry)
        let portion = try PortionEstimator().estimate(evidence: [.exactGrams(grams: 100)], food: resolution.autoPreselect)
        let dish = try MealEstimator().estimateDish(
            MealDishEstimationInput(
                name: "红烧豆腐",
                cookingMethod: "braise",
                ingredients: [
                    MealIngredientEstimationInput(
                        label: entry.name,
                        resolution: resolution,
                        portion: portion,
                        massBasis: .cooked
                    )
                ],
                inferredOilGrams: try EstimateRange(low: 8, likely: 12, high: 18)
            )
        )

        XCTAssertEqual(dish.ingredients.count, 1)
        XCTAssertEqual(dish.nutrients.energyKcal.likely, 150, accuracy: 0.001)
    }

    func testProductionMealEstimatorReportsP50P95AgainstLatencyTarget() throws {
        let input = try makePerformanceInput(ingredientCount: 12)
        let estimator = MealEstimator()
        let warmupCount = 10
        let sampleCount = 100
        for _ in 0..<warmupCount {
            _ = try estimator.estimateDish(input)
        }

        var durationsNanoseconds: [UInt64] = []
        durationsNanoseconds.reserveCapacity(sampleCount)
        var energyChecksum = 0.0
        for _ in 0..<sampleCount {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let estimate = try estimator.estimateDish(input)
            durationsNanoseconds.append(DispatchTime.now().uptimeNanoseconds - startedAt)
            energyChecksum += estimate.nutrients.energyKcal.likely
        }

        let sortedDurations = durationsNanoseconds.sorted()
        let p50 = sortedDurations[(sampleCount - 1) * 50 / 100]
        let p95 = sortedDurations[(sampleCount * 95 + 99) / 100 - 1]
        let environment = ProcessInfo.processInfo.environment
        let deviceName = environment["SIMULATOR_DEVICE_NAME"] ?? "macOS test host"
        let modelIdentifier = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "macOS runner"
        print(
            "DENSOSO_PERF scenario=production_meal_estimator "
                + "device=\(deviceName) model=\(modelIdentifier) "
                + "os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "ingredients=12 warmups=\(warmupCount) samples=\(sampleCount) "
                + "p50_us=\(Double(p50) / 1_000) p95_us=\(Double(p95) / 1_000)"
        )

        XCTAssertGreaterThan(energyChecksum, 0)
        XCTAssertLessThanOrEqual(p95, 100_000_000, "12-ingredient production MealEstimator p95 exceeded 100 ms")
    }

    func testUnknownMacroRemainsNil() throws {
        let entry = FoodCatalogEntry(
            id: "unknown-macro",
            name: "标签食品",
            preparation: .unknown,
            category: "packaged",
            nutrients: FoodNutrientProfile(energyKcalPer100Grams: 200),
            sourceVersion: "fixture"
        )
        let resolution = selected(entry)
        let portion = try PortionEstimator().estimate(evidence: [.exactGrams(grams: 100)], food: resolution.autoPreselect)
        let dish = try MealEstimator().estimateDish(
            MealDishEstimationInput(
                name: entry.name,
                ingredients: [
                    MealIngredientEstimationInput(
                        label: entry.name,
                        resolution: resolution,
                        portion: portion,
                        massBasis: .edibleRaw
                    )
                ]
            )
        )

        XCTAssertNil(dish.nutrients.proteinGrams)
        XCTAssertNil(dish.nutrients.fatGrams)
        XCTAssertNil(dish.nutrients.carbohydrateGrams)
    }

    func testOnlyLocalFoodCatalogCandidatesWriteLocalFoodIDs() throws {
        let localEntry = FoodCatalogEntry(
            id: "food:local-1",
            localFoodID: "local-1",
            name: "本地食品",
            preparation: .unknown,
            category: "test",
            nutrients: FoodNutrientProfile(energyKcalPer100Grams: 100),
            sourceVersion: "fixture"
        )
        let externalEntry = FoodCatalogEntry(
            id: "barcode:6901234567892",
            name: "外部包装食品",
            preparation: .unknown,
            category: "packaged",
            nutrients: FoodNutrientProfile(energyKcalPer100Grams: 100),
            sourceVersion: "external"
        )

        let localDish = try makeDish(entry: localEntry)
        let externalDish = try makeDish(entry: externalEntry)

        XCTAssertEqual(localDish.ingredients.first?.foodID, "local-1")
        XCTAssertNil(externalDish.ingredients.first?.foodID)
    }

    func testNutritionLabelParsesKJAndKeepsMissingMacrosNil() {
        let parsed = NutritionLabelParser().parse(lines: [
            "测试燕麦棒",
            "每份 40g",
            "能量 840 kJ",
            "蛋白质 6.5g",
        ])

        XCTAssertEqual(parsed?.productName, "测试燕麦棒")
        XCTAssertEqual(parsed?.energyKcal ?? 0, 200.76, accuracy: 0.02)
        XCTAssertEqual(parsed?.proteinGrams, 6.5)
        XCTAssertNil(parsed?.fatGrams)
        XCTAssertNil(parsed?.carbohydrateGrams)
    }

    func testNutritionLabelRejectsMixedOrMissingBasis() {
        let parser = NutritionLabelParser()

        XCTAssertNil(parser.parse(lines: ["每份 40g", "每100g", "能量 200 kcal"]))
        XCTAssertNil(parser.parse(lines: ["能量 200 kcal", "蛋白质 5g"]))
    }

    func testUserExactPortionIsReportedNotMeasuredAndRejectsInfinity() throws {
        let exact = try PortionEstimator().estimate(
            evidence: [.exactGrams(grams: 200)],
            food: nil
        )

        XCTAssertFalse(exact.isMeasured)
        XCTAssertEqual(exact.source, .userReportedExact)
        XCTAssertThrowsError(
            try PortionEstimate(
                lowGrams: 1,
                likelyGrams: 2,
                highGrams: .infinity,
                isMeasured: false
            )
        )
    }

    func testPortionEvidenceIntersectsEqualPriorityAndRetainsConflicts() throws {
        let estimator = PortionEstimator()
        let intersected = try estimator.estimate(
            evidence: [
                .packageServing(gramsPerServing: 100, count: 1),
                .packageServing(gramsPerServing: 104, count: 1),
            ],
            food: nil
        )
        XCTAssertEqual(intersected.lowGrams, 98.8, accuracy: 0.01)
        XCTAssertEqual(intersected.highGrams, 105, accuracy: 0.01)
        XCTAssertTrue(intersected.conflicts.isEmpty)

        let conflict = try estimator.estimate(
            evidence: [
                .approximateGrams(grams: 100),
                .packageServing(gramsPerServing: 200, count: 1),
            ],
            food: nil
        )
        XCTAssertEqual(conflict.source, .approximateGrams)
        XCTAssertEqual(conflict.conflicts.count, 1)
        XCTAssertFalse(conflict.isMeasured)

        let corrected = try estimator.estimate(
            evidence: [
                .userCorrection(low: 130, likely: 130, high: 130),
                .kitchenScale(grams: 100),
                .packageServing(gramsPerServing: 250, count: 1),
            ],
            food: nil
        )
        XCTAssertEqual(corrected.lowGrams, 130)
        XCTAssertEqual(corrected.likelyGrams, 130)
        XCTAssertEqual(corrected.highGrams, 130)
        XCTAssertEqual(corrected.source, .userCorrection)
        XCTAssertFalse(corrected.isMeasured)
        XCTAssertEqual(corrected.conflicts.count, 2)
    }

    func testClarificationSelectorReturnsAtMostOneHighValueQuestion() throws {
        let context = ClarificationContext(
            energyKcal: try EstimateRange(low: 100, likely: 300, high: 600),
            candidates: [
                ClarificationCandidate(
                    kind: .portion,
                    prompt: "大约是一小碗还是一大碗？",
                    expectedEnergyRangeReduction: 0.4,
                    userEffort: 1
                ),
                ClarificationCandidate(
                    kind: .hiddenIngredient,
                    prompt: "这道菜油多吗？",
                    expectedEnergyRangeReduction: 0.25,
                    userEffort: 1
                ),
            ]
        )

        let question = ClarificationSelector().selectOne(from: context)

        XCTAssertEqual(question?.kind, .portion)
    }

    private func fixtureCatalog() -> [FoodCatalogEntry] {
        [
            FoodCatalogEntry(
                id: "rice-cooked",
                name: "米饭(熟)",
                aliases: ["熟米饭", "白米饭"],
                preparation: .cooked,
                category: "staple",
                nutrients: FoodNutrientProfile(
                    energyKcalPer100Grams: 116,
                    proteinGramsPer100Grams: 2.6,
                    fatGramsPer100Grams: 0.3,
                    carbohydrateGramsPer100Grams: 25.9
                ),
                sourceVersion: "fixture"
            ),
            FoodCatalogEntry(
                id: "rice-raw",
                name: "大米(生)",
                aliases: ["生大米", "大米"],
                preparation: .raw,
                category: "staple",
                nutrients: FoodNutrientProfile(
                    energyKcalPer100Grams: 346,
                    proteinGramsPer100Grams: 7.4,
                    fatGramsPer100Grams: 0.8,
                    carbohydrateGramsPer100Grams: 77.9
                ),
                sourceVersion: "fixture"
            ),
        ]
    }

    private func selected(_ entry: FoodCatalogEntry) -> FoodResolution {
        let breakdown = FoodScoreBreakdown(
            lexicalMatch: 1,
            preparationCompatibility: 1,
            categoryCompatibility: 1,
            sourceQuality: 1,
            confirmedUserHistory: 0
        )
        let candidate = FoodCandidate(
            entry: entry,
            score: breakdown.finalScore,
            breakdown: breakdown,
            evidence: []
        )
        return FoodResolution(candidates: [candidate], autoPreselect: candidate)
    }

    private func makePerformanceInput(ingredientCount: Int) throws -> MealDishEstimationInput {
        var ingredients: [MealIngredientEstimationInput] = []
        ingredients.reserveCapacity(ingredientCount)
        for index in 0..<ingredientCount {
            let offset = Double(index)
            let entry = FoodCatalogEntry(
                id: "performance-food-\(index)",
                name: "performance-food-\(index)",
                preparation: .cooked,
                category: "staple",
                nutrients: FoodNutrientProfile(
                    energyKcalPer100Grams: 90 + offset * 4,
                    proteinGramsPer100Grams: 4 + offset / 2,
                    fatGramsPer100Grams: 1 + offset / 4,
                    carbohydrateGramsPer100Grams: 15 + offset
                ),
                sourceVersion: "meal-estimator-performance-fixture-v1"
            )
            let resolution = selected(entry)
            let portion = try PortionEstimator().estimate(
                evidence: [.exactGrams(grams: 75 + offset * 5)],
                food: resolution.autoPreselect
            )
            ingredients.append(
                MealIngredientEstimationInput(
                    label: entry.name,
                    resolution: resolution,
                    portion: portion,
                    massBasis: .cooked
                )
            )
        }

        return MealDishEstimationInput(
            name: "12 项复合餐性能 fixture",
            cookingMethod: "stirFry",
            ingredients: ingredients,
            inferredOilGrams: try EstimateRange(low: 4, likely: 8, high: 12)
        )
    }

    private func makeDish(entry: FoodCatalogEntry) throws -> MealDishDraft {
        let resolution = selected(entry)
        let portion = try PortionEstimator().estimate(
            evidence: [.exactGrams(grams: 100)],
            food: resolution.autoPreselect
        )
        return try MealEstimator().estimateDish(
            MealDishEstimationInput(
                name: entry.name,
                ingredients: [
                    MealIngredientEstimationInput(
                        label: entry.name,
                        resolution: resolution,
                        portion: portion,
                        massBasis: .edibleRaw
                    )
                ]
            )
        )
    }
}
