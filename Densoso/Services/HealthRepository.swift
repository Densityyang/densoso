import Foundation
import SwiftData
import DensosoDomain

/// Coordinates local health-record writes and their derived daily metrics.
/// SwiftData persists both the source change and its projection with one save.
@MainActor
final class HealthRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func insert(_ meal: MealRecord) throws {
        try write(affecting: [meal.date]) { _ in
            modelContext.insert(meal)
            enqueue(operation: "upsertMeal", recordID: meal.id)
        }
    }

    func insert(_ workout: WorkoutRecord) throws {
        try write(affecting: [workout.date]) { _ in
            modelContext.insert(workout)
            enqueue(operation: "upsertWorkout", recordID: workout.id)
        }
    }

    func delete(_ meal: MealRecord) throws {
        try write(affecting: [meal.date]) { _ in
            enqueue(operation: "deleteMeal", recordID: meal.id)
            modelContext.delete(meal)
        }
    }

    func delete(_ workout: WorkoutRecord) throws {
        try write(affecting: [workout.date]) { _ in
            enqueue(operation: "deleteWorkout", recordID: workout.id)
            modelContext.delete(workout)
        }
    }

    /// Applies HealthKit changes atomically with the corresponding anchor update.
    /// Imported records never enter the outbound HealthKit outbox, preventing sync echo.
    func applyImportedWorkouts(
        _ snapshots: [WorkoutSnapshot],
        deletedHealthKitUUIDs: [UUID],
        nextAnchorData: Data,
        stream: String = "workouts"
    ) throws {
        try write(affecting: snapshots.map(\.startedAt)) { affectedDates in
            let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>())
            var workoutsByHealthKitUUID: [UUID: WorkoutRecord] = [:]
            for workout in workouts {
                if let healthKitUUID = workout.healthKitUUID, workoutsByHealthKitUUID[healthKitUUID] == nil {
                    workoutsByHealthKitUUID[healthKitUUID] = workout
                }
            }

            for snapshot in snapshots {
                if let existing = workoutsByHealthKitUUID[snapshot.healthKitUUID] {
                    affectedDates.insert(existing.date)
                    apply(snapshot, to: existing)
                    affectedDates.insert(existing.date)
                } else {
                    let workout = WorkoutRecord()
                    apply(snapshot, to: workout)
                    modelContext.insert(workout)
                    workoutsByHealthKitUUID[snapshot.healthKitUUID] = workout
                    affectedDates.insert(workout.date)
                }
            }

            for healthKitUUID in deletedHealthKitUUIDs {
                for workout in workouts where workout.healthKitUUID == healthKitUUID {
                    affectedDates.insert(workout.date)
                    modelContext.delete(workout)
                }
            }

            if let cursor = try modelContext.fetch(FetchDescriptor<HealthKitImportCursor>()).first(where: { $0.stream == stream }) {
                cursor.anchorData = nextAnchorData
                cursor.updatedAt = Date()
            } else {
                modelContext.insert(HealthKitImportCursor(stream: stream, anchorData: nextAnchorData))
            }
        }
    }

    func anchorData(for stream: String = "workouts") throws -> Data? {
        try modelContext.fetch(FetchDescriptor<HealthKitImportCursor>()).first(where: { $0.stream == stream })?.anchorData
    }

    func pendingRouteHealthKitUUIDs() throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<WorkoutRecord>()).compactMap { workout in
            workout.routeStatus == WorkoutRouteStatus.pending.rawValue ? workout.healthKitUUID : nil
        }
    }

    func markImportedRouteAvailable(healthKitUUID: UUID, pointCount: Int) throws {
        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>())
        guard let workout = workouts.first(where: { $0.healthKitUUID == healthKitUUID }) else { return }

        try write(affecting: [workout.date]) { _ in
            workout.routeStatus = WorkoutRouteStatus.available.rawValue
            workout.routePointCount = max(pointCount, 0)
            workout.updatedAt = Date()
        }
    }

    private func apply(_ snapshot: WorkoutSnapshot, to workout: WorkoutRecord) {
        let resolvedEnergy = snapshot.resolvedEnergy
        workout.date = snapshot.startedAt
        workout.type = snapshot.activityType
        workout.durationMinutes = Int((snapshot.duration / 60).rounded())
        workout.estimatedCaloriesBurned = Int((resolvedEnergy?.kilocalories ?? 0).rounded())
        workout.healthKitUUID = snapshot.healthKitUUID
        workout.logicalSessionID = snapshot.logicalSessionID
        workout.workoutOrigin = snapshot.origin.rawValue
        workout.energySource = resolvedEnergy?.source.rawValue
        workout.sourceBundleIdentifier = snapshot.sourceBundleIdentifier
        workout.sourceVersion = snapshot.sourceVersion
        workout.sourceRevision = snapshot.sourceRevision
        workout.deviceName = snapshot.deviceName
        workout.deviceModel = snapshot.deviceModel
        workout.dataQuality = snapshot.dataQuality.rawValue
        workout.routeStatus = snapshot.routeStatus.rawValue
        workout.updatedAt = Date()
    }

    private func write(affecting dates: [Date], _ change: (inout Set<Date>) throws -> Void) throws {
        do {
            var affectedDates = Set(dates)
            try change(&affectedDates)
            for date in affectedDates {
                try DailyMetricsProjector.reproject(on: date, in: modelContext)
            }
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
