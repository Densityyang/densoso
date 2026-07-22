import Foundation
import SwiftData

/// Coordinates local health-record writes and their derived daily metrics.
/// SwiftData persists both the source change and its projection with one save.
@MainActor
final class HealthRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func insert(_ meal: MealRecord) throws {
        try write(affecting: meal.date) {
            modelContext.insert(meal)
            enqueue(operation: "upsertMeal", recordID: meal.id)
        }
    }

    func insert(_ workout: WorkoutRecord) throws {
        try write(affecting: workout.date) {
            modelContext.insert(workout)
            enqueue(operation: "upsertWorkout", recordID: workout.id)
        }
    }

    func delete(_ meal: MealRecord) throws {
        try write(affecting: meal.date) {
            enqueue(operation: "deleteMeal", recordID: meal.id)
            modelContext.delete(meal)
        }
    }

    func delete(_ workout: WorkoutRecord) throws {
        try write(affecting: workout.date) {
            enqueue(operation: "deleteWorkout", recordID: workout.id)
            modelContext.delete(workout)
        }
    }

    private func write(affecting date: Date, _ change: () throws -> Void) throws {
        do {
            try change()
            try DailyMetricsProjector.reproject(on: date, in: modelContext)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func enqueue(operation: String, recordID: UUID) {
        modelContext.insert(HealthSyncOutboxEntry(operation: operation, recordID: recordID))
    }
}
