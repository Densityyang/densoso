import Foundation
import SwiftData

@Model
final class DailyMetrics {
    @Attribute(.unique) var date: Date
    var bmrKcal: Int
    var activeCaloriesKcal: Int
    var totalExpenditureKcal: Int
    var totalIntakeKcal: Int
    var deficitKcal: Int
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var mealCount: Int
    var workoutCount: Int
    var computedAt: Date

    init(
        date: Date,
        bmrKcal: Int = 0,
        activeCaloriesKcal: Int = 0,
        totalExpenditureKcal: Int = 0,
        totalIntakeKcal: Int = 0,
        deficitKcal: Int = 0,
        proteinG: Double = 0,
        fatG: Double = 0,
        carbsG: Double = 0,
        mealCount: Int = 0,
        workoutCount: Int = 0
    ) {
        self.date = Calendar.current.startOfDay(for: date)
        self.bmrKcal = bmrKcal
        self.activeCaloriesKcal = activeCaloriesKcal
        self.totalExpenditureKcal = totalExpenditureKcal
        self.totalIntakeKcal = totalIntakeKcal
        self.deficitKcal = deficitKcal
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
        self.mealCount = mealCount
        self.workoutCount = workoutCount
        self.computedAt = Date()
    }
}