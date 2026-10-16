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
            DensosoSchemaV4.self,
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
            .custom(
                fromVersion: DensosoSchemaV3.self,
                toVersion: DensosoSchemaV4.self,
                willMigrate: nil,
                didMigrate: { context in
                    let profiles = try context.fetch(
                        FetchDescriptor<DensosoSchemaV4.UserProfile>()
                    )
                    var migratedWeights = try context.fetch(
                        FetchDescriptor<DensosoSchemaV4.WeightRecord>()
                    )
                    let legacyEpoch = Date(timeIntervalSince1970: 0)

                    for profile in profiles {
                        let validBirthDate = profile.dateOfBirth.flatMap { date -> Date? in
                            date != legacyEpoch && date <= profile.updatedAt ? date : nil
                        }
                        profile.dateOfBirth = validBirthDate
                        profile.profileNeedsCompletion = validBirthDate == nil
                        profile.profileKey = "primary"

                        context.insert(
                            DensosoSchemaV4.ProfileRevisionRecord(
                                profileKey: profile.profileKey,
                                effectiveFrom: profile.updatedAt,
                                dateOfBirth: validBirthDate,
                                biologicalSex: profile.biologicalSex,
                                heightCm: profile.heightCm,
                                weightKg: profile.weightKg,
                                activityLevel: profile.activityLevel,
                                source: "legacyMigration",
                                createdAt: profile.updatedAt
                            )
                        )

                        let history = try JSONDecoder().decode(
                            [LegacyProfileWeightEntry].self,
                            from: Data(profile.weightHistoryJSON.utf8)
                        )

                        for entry in history
                        where entry.date.timeIntervalSince1970.isFinite && entry.kg.isFinite && entry.kg > 0 {
                            let alreadyStored = migratedWeights.contains {
                                $0.measuredAt == entry.date && $0.kilograms == entry.kg
                            }
                            guard !alreadyStored else { continue }

                            let observation = DensosoSchemaV4.WeightRecord(
                                sourceActionKey: "legacy-profile-weight-\(UUID().uuidString.lowercased())",
                                measuredAt: entry.date,
                                kilograms: entry.kg,
                                source: "densoso",
                                algorithmVersion: "v4-migration",
                                confidence: 0.75
                            )
                            context.insert(observation)
                            migratedWeights.append(observation)
                        }
                    }

                    let metrics = try context.fetch(
                        FetchDescriptor<DensosoSchemaV4.DailyMetrics>()
                    )
                    for metric in metrics {
                        let intake = Double(metric.totalIntakeKcal)
                        let expenditure = Double(metric.totalExpenditureKcal)
                        let balance = Double(metric.deficitKcal)
                        metric.intakeEnergyLowKcal = intake
                        metric.intakeEnergyLikelyKcal = intake
                        metric.intakeEnergyHighKcal = intake
                        metric.expenditureEnergyLowKcal = expenditure
                        metric.expenditureEnergyLikelyKcal = expenditure
                        metric.expenditureEnergyHighKcal = expenditure
                        metric.energyBalanceLowKcal = balance
                        metric.energyBalanceLikelyKcal = balance
                        metric.energyBalanceHighKcal = balance
                        metric.energyQuality = "legacy"
                        metric.projectionVersion = "v3-legacy"
                        metric.sourceFingerprint = ""
                        metric.requiresRecompute = true
                    }

                    try context.save()
                }
            ),
        ]
    }
}

private struct LegacyProfileWeightEntry: Decodable {
    let date: Date
    let kg: Double
}
