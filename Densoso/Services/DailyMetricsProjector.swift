import Foundation
import SwiftData

/// The sole projection path from health records to their daily aggregate.
@MainActor
enum DailyMetricsProjector {
    static func reproject(on date: Date, in modelContext: ModelContext) throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let mealPredicate = #Predicate<MealRecord> { $0.date >= day && $0.date < nextDay }
        let workoutPredicate = #Predicate<WorkoutRecord> { $0.date >= day && $0.date < nextDay }

        let meals = try modelContext.fetch(FetchDescriptor<MealRecord>(predicate: mealPredicate))
        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>(predicate: workoutPredicate))
        let profile = try modelContext.fetch(FetchDescriptor<UserProfile>()).first ?? UserProfile()
        let projected = CaloricEngine.computeDailyMetrics(date: day, meals: meals, workouts: workouts, userProfile: profile)

        let metricPredicate = #Predicate<DailyMetrics> { $0.date == day }
        if let existing = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: metricPredicate)).first {
            copy(projected, to: existing)
        } else {
            modelContext.insert(projected)
        }
    }

    private static func copy(_ source: DailyMetrics, to destination: DailyMetrics) {
        destination.bmrKcal = source.bmrKcal
        destination.activeCaloriesKcal = source.activeCaloriesKcal
        destination.totalExpenditureKcal = source.totalExpenditureKcal
        destination.totalIntakeKcal = source.totalIntakeKcal
        destination.deficitKcal = source.deficitKcal
        destination.proteinG = source.proteinG
        destination.fatG = source.fatG
        destination.carbsG = source.carbsG
        destination.mealCount = source.mealCount
        destination.workoutCount = source.workoutCount
        destination.computedAt = source.computedAt
    }
}
