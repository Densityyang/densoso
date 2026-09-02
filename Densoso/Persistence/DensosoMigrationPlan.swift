import DensosoDomain
import Foundation
import SwiftData

enum DensosoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            DensosoSchemaV1.self,
            DensosoSchemaV1Bridge.self,
            DensosoSchemaV2.self,
            DensosoSchemaV2Bridge.self,
            DensosoSchemaV3.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: DensosoSchemaV1.self, toVersion: DensosoSchemaV1Bridge.self),
            .custom(
                fromVersion: DensosoSchemaV1Bridge.self,
                toVersion: DensosoSchemaV2.self,
                willMigrate: { context in
                    let workouts = try context.fetch(
                        FetchDescriptor<DensosoSchemaV1Bridge.WorkoutRecord>()
                    )
                    for workout in workouts {
                        workout.updatedAt = workout.createdAt
                        workout.workoutOrigin = "userEntered"
                        workout.energySource = "userEntered"
                        workout.dataQuality = "complete"
                        workout.routeStatus = "unavailable"
                    }
                    try context.save()
                },
                didMigrate: nil
            ),
            .lightweight(fromVersion: DensosoSchemaV2.self, toVersion: DensosoSchemaV2Bridge.self),
            .custom(
                fromVersion: DensosoSchemaV2Bridge.self,
                toVersion: DensosoSchemaV3.self,
                willMigrate: { context in
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let meals = try context.fetch(
                        FetchDescriptor<DensosoSchemaV2Bridge.MealRecord>()
                    )
                    for meal in meals {
                        let energy = Double(meal.totalCaloriesKcal)
                        meal.energyLowKcal = energy
                        meal.energyLikelyKcal = energy
                        meal.energyHighKcal = energy
                        meal.proteinLowG = meal.proteinG
                        meal.proteinLikelyG = meal.proteinG
                        meal.proteinHighG = meal.proteinG
                        meal.fatLowG = meal.fatG
                        meal.fatLikelyG = meal.fatG
                        meal.fatHighG = meal.fatG
                        meal.carbsLowG = meal.carbsG
                        meal.carbsLikelyG = meal.carbsG
                        meal.carbsHighG = meal.carbsG
                        meal.sourceActionKey = "legacy-meal-\(meal.id.uuidString.lowercased())"
                        meal.evidenceData = try encoder.encode([
                            EvidenceSnapshot(
                                id: meal.id,
                                grade: .legacyPointEstimate,
                                sourceID: "swiftdata-v2",
                                sourceVersion: meal.algorithmVersion,
                                summary: "Migrated without recalculating the historical point estimate."
                            )
                        ])

                        for dish in meal.dishes {
                            let dishEnergy = Double(dish.estimatedCaloriesKcal)
                            dish.id = UUID()
                            dish.energyLowKcal = dishEnergy
                            dish.energyLikelyKcal = dishEnergy
                            dish.energyHighKcal = dishEnergy
                            dish.proteinLowG = dish.estimatedProteinG
                            dish.proteinLikelyG = dish.estimatedProteinG
                            dish.proteinHighG = dish.estimatedProteinG
                            dish.fatLowG = dish.estimatedFatG
                            dish.fatLikelyG = dish.estimatedFatG
                            dish.fatHighG = dish.estimatedFatG
                            dish.carbsLowG = dish.estimatedCarbsG
                            dish.carbsLikelyG = dish.estimatedCarbsG
                            dish.carbsHighG = dish.estimatedCarbsG
                            dish.evidenceData = meal.evidenceData
                            dish.algorithmVersion = meal.algorithmVersion
                        }
                    }

                    let outboxEntries = try context.fetch(
                        FetchDescriptor<DensosoSchemaV2Bridge.HealthSyncOutboxEntry>()
                    )
                    for entry in outboxEntries {
                        entry.idempotencyKey = "legacy-outbox-\(entry.id.uuidString.lowercased())"
                        entry.payloadData = try encoder.encode([
                            "operation": entry.operation,
                            "recordID": entry.recordID.uuidString.lowercased(),
                        ])
                        entry.attemptCount = 0
                        switch entry.state {
                        case "pending", "sending", "succeeded", "retryable", "terminal":
                            break
                        case "error":
                            entry.state = "retryable"
                        default:
                            entry.state = "terminal"
                        }
                        entry.syncIdentifier = "densoso.\(entry.operation).\(entry.recordID.uuidString.lowercased())"
                        entry.syncVersion = 1
                    }
                    try context.save()
                },
                didMigrate: nil
            ),
        ]
    }
}
