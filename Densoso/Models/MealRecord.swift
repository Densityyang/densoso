import Foundation
import SwiftData

@Model
final class MealRecord {
    var date: Date
    var mealType: String          // breakfast / lunch / dinner / snack
    var totalCaloriesKcal: Int
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var notes: String?
    var confidence: String        // high / medium / low / userConfirmed
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \DishEntry.mealRecord)
    var dishes: [DishEntry] = []

    init(
        date: Date = Date(),
        mealType: String = "lunch",
        totalCaloriesKcal: Int = 0,
        proteinG: Double = 0,
        fatG: Double = 0,
        carbsG: Double = 0,
        notes: String? = nil,
        confidence: String = "medium"
    ) {
        self.date = date
        self.mealType = mealType
        self.totalCaloriesKcal = totalCaloriesKcal
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.notes = notes
        self.confidence = confidence
        self.createdAt = Date()
    }
}