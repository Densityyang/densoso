import CryptoKit
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
            DensosoSchemaV5.self,
            DensosoSchemaV6.self,
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
            .lightweight(fromVersion: DensosoSchemaV4.self, toVersion: DensosoSchemaV5.self),
            .custom(
                fromVersion: DensosoSchemaV5.self,
                toVersion: DensosoSchemaV6.self,
                willMigrate: nil,
                didMigrate: { context in
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .millisecondsSince1970
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .millisecondsSince1970
                    encoder.outputFormatting = [.sortedKeys]
                    let records = try context.fetch(
                        FetchDescriptor<DensosoSchemaV4.DailyHealthSnapshotRecord>(
                            sortBy: [SortDescriptor(\DensosoSchemaV4.DailyHealthSnapshotRecord.dayKey)]
                        )
                    )
                    let workouts = try context.fetch(FetchDescriptor<DensosoSchemaV4.WorkoutRecord>())
                    var locationsBySampleID: [UUID: (stream: String, dayKey: String, startDate: Date, endDate: Date)] = [:]
                    let decodedSnapshots = try records.map { record in
                        (record, try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData))
                    }
                    var existingDayKeys = Set(records.map(\.dayKey))
                    let calendar = Calendar.current
                    let workoutsByDay = Dictionary(grouping: workouts) {
                        calendar.startOfDay(for: $0.date)
                    }
                    var samplesByStartDay: [Date: [UUID: HealthSampleSnapshot]] = [:]
                    let legacySamples = HealthSampleSnapshot.deduplicated(
                        decodedSnapshots.flatMap { $0.1.healthKitSamples ?? [] }
                    )
                    for sample in legacySamples {
                        let sampleDay = calendar.startOfDay(for: sample.startDate)
                        samplesByStartDay[sampleDay, default: [:]][sample.id] = sample
                    }
                    for samples in samplesByStartDay.values {
                        for sample in samples.values {
                            locationsBySampleID[sample.id] = (
                                sample.metric.rawValue,
                                Self.dayKey(for: sample.startDate),
                                sample.startDate,
                                sample.endDate
                            )
                        }
                    }
                    for (record, snapshot) in decodedSnapshots {
                        let day = calendar.startOfDay(for: snapshot.dayStart)
                        let samples = (samplesByStartDay[day] ?? [:]).values.sorted(
                            by: HealthSampleSnapshot.stableDeduplicationOrder
                        )
                        let dayWorkouts = workoutsByDay[day] ?? []
                        let previousDay = calendar.date(byAdding: .day, value: -1, to: day)
                        let previousSleepSamples = previousDay.flatMap { previous in
                            samplesByStartDay[previous].map { Array($0.values) }
                        } ?? []
                        let wakeDaySleepSamples = previousSleepSamples + samples
                        let summary = DailyHealthSampleSummaryBuilder.build(
                            samples: samples,
                            dayStart: snapshot.dayStart,
                            sleepSamples: wakeDaySleepSamples,
                            workouts: dayWorkouts
                        )
                        var readStates = snapshot.healthReadStates ?? [:]
                        for sample in samples where readStates[sample.metric.rawValue] == nil {
                            readStates[sample.metric.rawValue] = .available
                        }
                        let cacheOnlySnapshot = Self.cacheOnly(
                            snapshot,
                            sampleSummary: summary,
                            healthReadStates: readStates
                        )
                        let payloadData = try encoder.encode(cacheOnlySnapshot)
                        record.payloadData = payloadData
                        record.algorithmVersion = DailyHealthSnapshot.currentAlgorithmVersion
                        record.snapshotHash = SHA256.hash(data: payloadData)
                            .map { String(format: "%02x", $0) }
                            .joined()
                    }

                    let allUniqueSamples = samplesByStartDay.values.flatMap { $0.values }
                    var sleepSamplesByWakeDay: [Date: [HealthSampleSnapshot]] = [:]
                    for sample in allUniqueSamples where sample.metric == .sleepAnalysis {
                        for wakeDay in Self.sleepWakeDays(startDate: sample.startDate, endDate: sample.endDate) {
                            sleepSamplesByWakeDay[wakeDay, default: []].append(sample)
                        }
                    }
                    for wakeDay in sleepSamplesByWakeDay.keys.sorted() {
                        let wakeDayKey = Self.dayKey(for: wakeDay)
                        guard existingDayKeys.insert(wakeDayKey).inserted else { continue }
                        let wakeSamples = (sleepSamplesByWakeDay[wakeDay] ?? []).sorted(
                            by: HealthSampleSnapshot.stableDeduplicationOrder
                        )
                        let summary = DailyHealthSampleSummary(
                            samples: [],
                            dayStart: wakeDay,
                            sleepSamples: wakeSamples
                        )
                        let cacheOnlySnapshot = DailyHealthSnapshot(
                            dayStart: wakeDay,
                            timezoneIdentifier: calendar.timeZone.identifier,
                            healthKitSampleSummary: summary,
                            healthReadStates: [HealthMetricID.sleepAnalysis.rawValue: .available],
                            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
                        )
                        let payloadData = try encoder.encode(cacheOnlySnapshot)
                        context.insert(DensosoSchemaV4.DailyHealthSnapshotRecord(
                            dayKey: wakeDayKey,
                            timezoneID: cacheOnlySnapshot.timezoneIdentifier,
                            payloadData: payloadData,
                            snapshotHash: SHA256.hash(data: payloadData)
                                .map { String(format: "%02x", $0) }
                                .joined(),
                            algorithmVersion: cacheOnlySnapshot.algorithmVersion
                        ))
                    }

                    for (sampleID, location) in locationsBySampleID.sorted(by: {
                        $0.key.uuidString < $1.key.uuidString
                    }) {
                        context.insert(DensosoSchemaV6.HealthKitSampleIndexRecord(
                            sampleID: sampleID,
                            stream: location.stream,
                            dayKey: location.dayKey,
                            startDate: location.startDate,
                            endDate: location.endDate,
                            pendingDayKeys: [],
                            isDeleted: false
                        ))
                    }
                    try context.save()
                }
            ),
        ]
    }

    private static func cacheOnly(
        _ snapshot: DailyHealthSnapshot,
        sampleSummary: DailyHealthSampleSummary,
        healthReadStates: [String: HealthReadState]
    ) -> DailyHealthSnapshot {
        DailyHealthSnapshot(
            dayStart: snapshot.dayStart,
            timezoneIdentifier: snapshot.timezoneIdentifier,
            energyIntakeKcal: snapshot.energyIntakeKcal,
            activeEnergyKcal: snapshot.activeEnergyKcal,
            restingEnergyKcal: snapshot.restingEnergyKcal,
            stepCount: snapshot.stepCount,
            exerciseMinutes: snapshot.exerciseMinutes,
            weightKilograms: snapshot.weightKilograms,
            healthKitSampleSummary: sampleSummary,
            healthReadStates: healthReadStates,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func sleepWakeDays(startDate: Date, endDate: Date) -> Set<Date> {
        guard startDate.timeIntervalSince1970.isFinite,
              endDate.timeIntervalSince1970.isFinite,
              endDate > startDate else { return [] }
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: startDate)
        let lastDay = calendar.startOfDay(for: endDate)
        guard let dayCount = calendar.dateComponents([.day], from: firstDay, to: lastDay).day,
              dayCount >= 0, dayCount <= 366 else { return [] }
        var affected = Set<Date>()
        for offset in 0...dayCount {
            guard let wakeDay = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let previousDay = calendar.date(byAdding: .day, value: -1, to: wakeDay),
                  let windowStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay),
                  let windowEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: wakeDay) else {
                continue
            }
            if endDate > windowStart && startDate < windowEnd { affected.insert(wakeDay) }
        }
        return affected
    }
}

private struct LegacyProfileWeightEntry: Decodable {
    let date: Date
    let kg: Double
}
