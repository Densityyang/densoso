import DensosoDomain
import Foundation
import SwiftData

@ModelActor
actor SwiftDataConfirmedFoodHistoryRepository: ConfirmedFoodHistoryProviding {
    func confirmedFoodIDs(matching label: String) async throws -> Set<String> {
        let normalizedLabel = FoodResolver.normalize(label)
        guard !normalizedLabel.isEmpty else { return [] }
        let meals = try modelContext.fetch(FetchDescriptor<MealRecord>())
        var identifiers: Set<String> = []
        for dish in meals.flatMap(\.dishes) {
            guard let data = dish.ingredientJSON.data(using: .utf8),
                  let ingredients = try? JSONDecoder().decode(
                      [MealIngredientDraft].self,
                      from: data
                  ) else { continue }
            for ingredient in ingredients {
                guard let foodID = ingredient.foodID else { continue }
                let normalizedName = FoodResolver.normalize(ingredient.name)
                if !normalizedName.isEmpty,
                   normalizedName.contains(normalizedLabel)
                    || normalizedLabel.contains(normalizedName) {
                    identifiers.insert(foodID)
                }
            }
        }
        return identifiers
    }
}
