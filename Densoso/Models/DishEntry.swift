import Foundation

extension DensosoSchemaV3.DishEntry {
    var ingredients: [IngredientEstimate] {
        guard let data = ingredientJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([IngredientEstimate].self, from: data)) ?? []
    }

    func setIngredients(_ estimates: [IngredientEstimate]) {
        if let data = try? JSONEncoder().encode(estimates),
           let json = String(data: data, encoding: .utf8) {
            ingredientJSON = json
        }
    }
}

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
