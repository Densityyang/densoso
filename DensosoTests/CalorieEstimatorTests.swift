import XCTest
@testable import Densoso

final class CalorieEstimatorTests: XCTestCase {
    func testExplicitOilIsAddedOnceWithoutCookingMultiplier() {
        let result = CalorieEstimator.estimate(
            ingredients: [ingredient(name: "鸡蛋", energy: 138, protein: 12.7, fat: 9, carbs: 1.5, amount: 100)],
            oil: .provided(grams: 10)
        )

        XCTAssertEqual(result.calories.low, 228)
        XCTAssertEqual(result.calories.likely, 228)
        XCTAssertEqual(result.calories.high, 228)
        XCTAssertEqual(result.proteinG, 12.7, accuracy: 0.001)
        XCTAssertEqual(result.fatG, 19, accuracy: 0.001)
        XCTAssertEqual(result.carbsG, 1.5, accuracy: 0.001)
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

    func testGrossRawMassAppliesEdibleFractionOnce() {
        let result = CalorieEstimator.estimate(
            ingredients: [ingredient(name: "带骨鱼", energy: 105, protein: 18.6, fat: 3.4, carbs: 0, amount: 100, edible: 58)],
            oil: .provided(grams: 0)
        )

        XCTAssertEqual(result.calories.likely, 61)
        XCTAssertEqual(result.proteinG, 10.788, accuracy: 0.001)
    }

    private func ingredient(name: String, energy: Int, protein: Double, fat: Double, carbs: Double, amount: Double, edible: Int = 100) -> CalorieEstimator.Ingredient {
        let item = FoodItem(id: 1, name: name, alias: nil, category: "test", edible: edible, energyKcal: energy,
                            proteinG: protein, fatG: fat, carbohydrateG: carbs, fiberG: nil)
        return CalorieEstimator.Ingredient(item: item, amountG: amount, massBasis: .grossRaw, matchScore: 1)
    }
}
