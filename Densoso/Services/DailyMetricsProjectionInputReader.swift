import Foundation
import SwiftData

struct DailyMetricsProjectionInputs {
    let meals: [MealRecord]
    let workouts: [WorkoutRecord]
    let sourceRecordRevisions: [String]
}

/// Loads complete daily projection inputs without allowing a day's record count
/// to determine how many rows a single SwiftData fetch materializes.
enum DailyMetricsProjectionInputReader {
    static let fetchBatchSize = 64

    static func read(
        on date: Date,
        calendar: Calendar,
        in modelContext: ModelContext
    ) throws -> DailyMetricsProjectionInputs {
        let day = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let meals = try meals(from: day, before: nextDay, in: modelContext)
        let workouts = try workouts(from: day, before: nextDay, in: modelContext)
        return DailyMetricsProjectionInputs(
            meals: meals,
            workouts: workouts,
            sourceRecordRevisions: sourceRecordRevisions(meals: meals, workouts: workouts)
        )
    }

    private static func sourceRecordRevisions(meals: [MealRecord], workouts: [WorkoutRecord]) -> [String] {
        let mealRevisions = meals.map {
            "meal:\($0.id.uuidString.lowercased()):created:\($0.createdAt.timeIntervalSince1970)"
        }
        let workoutRevisions = workouts.map {
            "workout:\($0.id.uuidString.lowercased()):created:\($0.createdAt.timeIntervalSince1970):updated:\($0.updatedAt.timeIntervalSince1970)"
        }
        return (mealRevisions + workoutRevisions).sorted()
    }

    private static func meals(from day: Date, before nextDay: Date, in modelContext: ModelContext) throws -> [MealRecord] {
        let basePredicate = #Predicate<MealRecord> { $0.date >= day && $0.date < nextDay }
        let sortDescriptors = [SortDescriptor(\MealRecord.date), SortDescriptor(\MealRecord.id)]
        var results: [MealRecord] = []
        var cursorDate: Date?
        var cursorID: UUID?

        while true {
            let predicate: Predicate<MealRecord>
            if let cursorDate, let cursorID {
                let lastDate = cursorDate
                let lastID = cursorID
                predicate = #Predicate<MealRecord> { meal in
                    meal.date >= day && meal.date < nextDay
                        && (meal.date > lastDate || (meal.date == lastDate && meal.id > lastID))
                }
            } else {
                predicate = basePredicate
            }
            var descriptor = FetchDescriptor<MealRecord>(predicate: predicate, sortBy: sortDescriptors)
            descriptor.fetchLimit = fetchBatchSize
            let page = try modelContext.fetch(descriptor)
            guard !page.isEmpty else { break }
            results.append(contentsOf: page)
            guard page.count == fetchBatchSize, let last = page.last else { break }
            cursorDate = last.date
            cursorID = last.id
        }
        return results
    }

    private static func workouts(
        from day: Date,
        before nextDay: Date,
        in modelContext: ModelContext
    ) throws -> [WorkoutRecord] {
        let basePredicate = #Predicate<WorkoutRecord> { $0.date >= day && $0.date < nextDay }
        let sortDescriptors = [SortDescriptor(\WorkoutRecord.date), SortDescriptor(\WorkoutRecord.id)]
        var results: [WorkoutRecord] = []
        var cursorDate: Date?
        var cursorID: UUID?

        while true {
            let predicate: Predicate<WorkoutRecord>
            if let cursorDate, let cursorID {
                let lastDate = cursorDate
                let lastID = cursorID
                predicate = #Predicate<WorkoutRecord> { workout in
                    workout.date >= day && workout.date < nextDay
                        && (workout.date > lastDate || (workout.date == lastDate && workout.id > lastID))
                }
            } else {
                predicate = basePredicate
            }
            var descriptor = FetchDescriptor<WorkoutRecord>(predicate: predicate, sortBy: sortDescriptors)
            descriptor.fetchLimit = fetchBatchSize
            let page = try modelContext.fetch(descriptor)
            guard !page.isEmpty else { break }
            results.append(contentsOf: page)
            guard page.count == fetchBatchSize, let last = page.last else { break }
            cursorDate = last.date
            cursorID = last.id
        }
        return results
    }
}
