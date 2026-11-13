import DensosoDomain
import Foundation
import SwiftData

enum ConfirmedFoodHistoryReadLimits {
    static let mealPageSize = 128
}

@ModelActor
actor SwiftDataConfirmedFoodHistoryRepository: ConfirmedFoodHistoryProviding {
    func confirmedFoodIDs(matching label: String) async throws -> Set<String> {
        let normalizedLabel = FoodResolver.normalize(label)
        guard !normalizedLabel.isEmpty else { return [] }
        var identifiers: Set<String> = []
        var cursor: (createdAt: Date, sourceActionKey: String)?
        let sortBy = [
            SortDescriptor(\MealRecord.createdAt),
            SortDescriptor(\MealRecord.sourceActionKey),
        ]
        while true {
            var descriptor: FetchDescriptor<MealRecord>
            if let cursor {
                let cursorCreatedAt = cursor.createdAt
                let cursorSourceActionKey = cursor.sourceActionKey
                let predicate = #Predicate<MealRecord> {
                    $0.createdAt > cursorCreatedAt
                        || ($0.createdAt == cursorCreatedAt && $0.sourceActionKey > cursorSourceActionKey)
                }
                descriptor = FetchDescriptor(predicate: predicate, sortBy: sortBy)
            } else {
                descriptor = FetchDescriptor(sortBy: sortBy)
            }
            descriptor.fetchLimit = ConfirmedFoodHistoryReadLimits.mealPageSize
            let meals = try modelContext.fetch(descriptor)
            guard !meals.isEmpty else { break }

            for meal in meals {
                for dish in meal.dishes {
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
            }

            guard meals.count == ConfirmedFoodHistoryReadLimits.mealPageSize,
                  let lastMeal = meals.last else { break }
            cursor = (createdAt: lastMeal.createdAt, sourceActionKey: lastMeal.sourceActionKey)
        }
        return identifiers
    }
}
