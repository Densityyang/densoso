import Foundation
import SwiftData

@Model
final class WeeklyReport {
    @Attribute(.unique) var weekStartDate: Date
    var weekEndDate: Date
    var totalDeficitKcal: Int
    var avgDailyDeficitKcal: Double
    var projectedWeightLossKg: Double
    var avgProteinG: Double
    var avgFatG: Double
    var avgCarbsG: Double
    var bestDay: Date?
    var worstDay: Date?
    var mealsCount: Int
    var workoutsCount: Int
    var compliance: Double
    var generatedAt: Date

    init(
        weekStartDate: Date,
        weekEndDate: Date,
        totalDeficitKcal: Int = 0,
        avgDailyDeficitKcal: Double = 0,
        projectedWeightLossKg: Double = 0,
        avgProteinG: Double = 0,
        avgFatG: Double = 0,
        avgCarbsG: Double = 0,
        bestDay: Date? = nil,
        worstDay: Date? = nil,
        mealsCount: Int = 0,
        workoutsCount: Int = 0,
        compliance: Double = 0
    ) {
        self.weekStartDate = weekStartDate
        self.weekEndDate = weekEndDate
        self.totalDeficitKcal = totalDeficitKcal
        self.avgDailyDeficitKcal = avgDailyDeficitKcal
        self.projectedWeightLossKg = projectedWeightLossKg
        self.avgProteinG = avgProteinG
        self.avgFatG = avgFatG
        self.avgCarbsG = avgCarbsG
        self.bestDay = bestDay
        self.worstDay = worstDay
        self.mealsCount = mealsCount
        self.workoutsCount = workoutsCount
        self.compliance = compliance
        self.generatedAt = Date()
    }
}