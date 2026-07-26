import Foundation
import HealthKit
import SwiftData

/// Re-checks routes independently of the workout anchor because routes may arrive later.
@MainActor
final class WorkoutRouteImporter {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func importPendingRoutes(in modelContext: ModelContext) {
        let repository = HealthRepository(modelContext: modelContext)
        guard let healthKitUUIDs = try? repository.pendingRouteHealthKitUUIDs() else { return }
        let healthStore = healthStore

        for healthKitUUID in healthKitUUIDs {
            let workoutQuery = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForObject(with: healthKitUUID),
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                guard error == nil, let workout = samples?.first as? HKWorkout else { return }

                let routeQuery = HKSampleQuery(
                    sampleType: HKSeriesType.workoutRoute(),
                    predicate: HKQuery.predicateForObjects(from: workout),
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, routes, routeError in
                    guard routeError == nil else { return }
                    let count = routes?.compactMap { $0 as? HKWorkoutRoute }.count ?? 0
                    guard count > 0 else { return }

                    Task { @MainActor in
                        try? repository.markImportedRouteAvailable(healthKitUUID: healthKitUUID, pointCount: count)
                    }
                }
                healthStore.execute(routeQuery)
            }
            healthStore.execute(workoutQuery)
        }
    }
}
