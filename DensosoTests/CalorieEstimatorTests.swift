import Dispatch
import Foundation
import XCTest
@testable import Densoso

final class CalorieEstimatorTests: XCTestCase {
    func testExplicitOilIsAddedOnceWithoutCookingMultiplier() throws {
        let result = CalorieEstimator.estimate(
            ingredients: [ingredient(name: "鸡蛋", energy: 138, protein: 12.7, fat: 9, carbs: 1.5, amount: 100)],
            oil: .provided(grams: 10)
        )

        XCTAssertEqual(result.calories.low, 228)
        XCTAssertEqual(result.calories.likely, 228)
        XCTAssertEqual(result.calories.high, 228)
        XCTAssertEqual(try XCTUnwrap(result.proteinG), 12.7, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.fatG), 19, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.carbsG), 1.5, accuracy: 0.001)
        XCTAssertEqual(result.ingredientEstimates.first?.oilCoefficient, 1)
    }

    func testInferredOilProducesAnHonestInterval() {
        let result = CalorieEstimator.estimate(
            ingredients: [ingredient(name: "鸡蛋", energy: 138, protein: 12.7, fat: 9, carbs: 1.5, amount: 100)],
            oil: .inferred(grams: 10)
        )

        XCTAssertEqual(result.calories.low, 183)
        XCTAssertEqual(result.calories.likely, 228)
        XCTAssertEqual(result.calories.high, 273)
    }

    func testGrossRawMassAppliesEdibleFractionOnce() throws {
        let result = CalorieEstimator.estimate(
            ingredients: [ingredient(name: "带骨鱼", energy: 105, protein: 18.6, fat: 3.4, carbs: 0, amount: 100, edible: 58)],
            oil: .provided(grams: 0)
        )

        XCTAssertEqual(result.calories.likely, 61)
        XCTAssertEqual(try XCTUnwrap(result.proteinG), 10.788, accuracy: 0.001)
    }

    func testDeterministicMealEstimateReportsP50P95AgainstLatencyTarget() {
        let ingredients = (0..<12).map { index in
            ingredient(
                name: "fixture-food-\(index)",
                energy: 80 + index * 7,
                protein: 8 + Double(index),
                fat: 3 + Double(index) / 2,
                carbs: 10 + Double(index),
                amount: 75 + Double(index) * 5,
                edible: 85 + index
            )
        }
        let warmupCount = 10
        let sampleCount = 100
        for _ in 0..<warmupCount {
            _ = CalorieEstimator.estimate(ingredients: ingredients, oil: .inferred(grams: 8))
        }

        var durationsNanoseconds: [UInt64] = []
        durationsNanoseconds.reserveCapacity(sampleCount)
        var calorieChecksum = 0
        for _ in 0..<sampleCount {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let result = CalorieEstimator.estimate(ingredients: ingredients, oil: .inferred(grams: 8))
            durationsNanoseconds.append(DispatchTime.now().uptimeNanoseconds - startedAt)
            calorieChecksum += result.calories.likely
        }

        let sortedDurations = durationsNanoseconds.sorted()
        let p50 = sortedDurations[(sampleCount - 1) * 50 / 100]
        let p95 = sortedDurations[(sampleCount * 95 + 99) / 100 - 1]
        let environment = ProcessInfo.processInfo.environment
        let deviceName = environment["SIMULATOR_DEVICE_NAME"] ?? "iPhone 17 Pro (Gate 13 destination)"
        let modelIdentifier = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iPhone 17 Pro destination"
        print(
            "DENSOSO_PERF scenario=deterministic_meal_estimate "
                + "device=\(deviceName) model=\(modelIdentifier) "
                + "os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "ingredients=12 warmups=\(warmupCount) samples=\(sampleCount) "
                + "p50_us=\(Double(p50) / 1_000) p95_us=\(Double(p95) / 1_000)"
        )

        XCTAssertGreaterThan(calorieChecksum, 0)
        XCTAssertLessThan(p95, 100_000_000, "12-ingredient deterministic estimate p95 exceeded 100 ms")
    }

    private func ingredient(name: String, energy: Int, protein: Double, fat: Double, carbs: Double, amount: Double, edible: Int = 100) -> CalorieEstimator.Ingredient {
        let item = FoodItem(id: 1, name: name, alias: nil, preparation: nil, isCookedComposite: nil,
                            category: "test", edible: edible, energyKcal: energy,
                            proteinG: protein, fatG: fat, carbohydrateG: carbs, fiberG: nil)
        return CalorieEstimator.Ingredient(item: item, amountG: amount, massBasis: .grossRaw, matchScore: 1)
    }
}
