import Foundation
import HealthKit
import SwiftData
import DensosoWorkoutDomain

/// Imports canonical HealthKit workouts with an anchored query.
/// The next anchor is saved only in the same SwiftData transaction as the changes it represents.
@MainActor
final class HealthKitWorkoutImporter {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func importChanges(in modelContext: ModelContext) {
        let repository = HealthRepository(modelContext: modelContext)

        do {
            let anchor = try repository.anchorData().flatMap(decodeAnchor)
            let query = HKAnchoredObjectQuery(
                type: HKObjectType.workoutType(),
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deletedObjects, newAnchor, error in
                guard let newAnchor else { return }

                do {
                    if let error { throw error }
                    let snapshots = (samples ?? [])
                        .compactMap { $0 as? HKWorkout }
                        .compactMap(Self.snapshot(from:))
                    let deletedUUIDs = (deletedObjects ?? []).map(\.uuid)
                    let anchorData = try Self.encode(newAnchor)

                    Task { @MainActor in
                        do {
                            try repository.applyImportedWorkouts(
                                snapshots,
                                deletedHealthKitUUIDs: deletedUUIDs,
                                nextAnchorData: anchorData
                            )
                        } catch {
                            // Keeping the prior anchor makes the complete page retryable.
                            return
                        }
                    }
                } catch {
                    return
                }
            }
            healthStore.execute(query)
        } catch {
            return
        }
    }

    private static func snapshot(from workout: HKWorkout) -> WorkoutSnapshot? {
        let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        let measuredEnergy = activeEnergy
            .flatMap { workout.statistics(for: $0)?.sumQuantity() }
            .map { $0.doubleValue(for: .kilocalorie()) }
        let sourceRevision = workout.sourceRevision
        let sourceBundleIdentifier = sourceRevision.source.bundleIdentifier
        let logicalSessionID = (workout.metadata?["com.densoso.logicalWorkoutSessionID"] as? String)
            .flatMap(UUID.init(uuidString:))

        let origin: WorkoutOrigin = sourceBundleIdentifier == "com.densoso.densoso"
            ? .watchHealthKit
            : .externalHealthKit
        let dataQuality: WorkoutDataQuality = measuredEnergy == nil ? .partial : .complete

        return try? WorkoutSnapshot(
            healthKitUUID: workout.uuid,
            logicalSessionID: logicalSessionID,
            startedAt: workout.startDate,
            duration: workout.duration,
            activityType: String(workout.workoutActivityType.rawValue),
            energyInput: .init(measuredKilocalories: measuredEnergy),
            origin: origin,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceVersion: sourceRevision.version,
            sourceRevision: sourceRevision.productType,
            deviceName: workout.device?.name,
            deviceModel: workout.device?.model,
            dataQuality: dataQuality,
            routeStatus: .pending
        )
    }

    private static func encode(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    private func decodeAnchor(_ data: Data) throws -> HKQueryAnchor? {
        try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}
