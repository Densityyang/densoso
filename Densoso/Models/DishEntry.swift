import Foundation
import SwiftData

@Model
final class DishEntry {
    var dishName: String
    var cookingMethod: String?       // steam / boil / stirFry / braise / dryFry / deepFry / roast / stew / unknown
    var ingredientJSON: String       // JSON: [{foodItemId, name, amountG, baseKcal, oilCoefficient, adjustedKcal}]
    var estimatedCaloriesKcal: Int
    var estimatedProteinG: Double
    var estimatedFatG: Double
    var estimatedCarbsG: Double
    var confidenceScore: Double      // 0.0 ~ 1.0
    var userCorrectionFactor: Double? // null = 未确认
    var createdAt: Date

    var mealRecord: MealRecord?

    init(
        dishName: String,
        cookingMethod: String? = nil,
        ingredientJSON: String = "[]",
        estimatedCaloriesKcal: Int = 0,
        estimatedProteinG: Double = 0,
        estimatedFatG: Double = 0,
        estimatedCarbsG: Double = 0,
        confidenceScore: Double = 0.5,
        userCorrectionFactor: Double? = nil
    ) {
        self.dishName = dishName
        self.cookingMethod = cookingMethod
        self.ingredientJSON = ingredientJSON
        self.estimatedCaloriesKcal = estimatedCaloriesKcal
        self.estimatedProteinG = estimatedProteinG
        self.estimatedFatG = estimatedFatG
        self.estimatedCarbsG = estimatedCarbsG
        self.confidenceScore = confidenceScore
        self.userCorrectionFactor = userCorrectionFactor
        self.createdAt = Date()
    }

    /// 从 JSON 解码食材分解
    var ingredients: [IngredientEstimate] {
        guard let data = ingredientJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([IngredientEstimate].self, from: data)) ?? []
    }

    /// 更新食材分解并重新编码
    func setIngredients(_ estimates: [IngredientEstimate]) {
        if let data = try? JSONEncoder().encode(estimates),
           let json = String(data: data, encoding: .utf8) {
            ingredientJSON = json
        }
    }
}

/// 单条食材估计（编码到 DishEntry.ingredientJSON 中）
struct IngredientEstimate: Codable, Equatable {
    var foodItemId: Int64
    var name: String
    var amountG: Double
    var baseCaloriesKcal: Double
    var oilCoefficient: Double
    var adjustedCaloriesKcal: Double

    static func == (lhs: IngredientEstimate, rhs: IngredientEstimate) -> Bool {
        lhs.foodItemId == rhs.foodItemId && lhs.amountG == rhs.amountG
    }
}