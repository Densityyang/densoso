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
            DensosoSchemaV7.self,
            DensosoSchemaV8.self,
            DensosoSchemaV9.self,
            DensosoSchemaV10.self,
            DensosoSchemaV11.self,
            DensosoSchemaV12.self,
            DensosoSchemaV13.self,
            DensosoSchemaV14.self,
            DensosoSchemaV15.self,
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
                        let legacyEnergy = Self.legacyEnergyPoint(meal.totalCaloriesKcal)
                        // Schema V3 requires scalar/range energy columns. Keep zero in
                        // those compatibility fields, but mark it unavailable below;
                        // V2 used zero as its missing-value default.
                        let energy = legacyEnergy ?? 0
                        meal.energyLowKcal = energy
                        meal.energyLikelyKcal = energy
                        meal.energyHighKcal = energy
                        let protein = Self.legacyMacroPoint(meal.proteinG)
                        meal.proteinLowG = protein
                        meal.proteinLikelyG = protein
                        meal.proteinHighG = protein
                        let fat = Self.legacyMacroPoint(meal.fatG)
                        meal.fatLowG = fat
                        meal.fatLikelyG = fat
                        meal.fatHighG = fat
                        let carbs = Self.legacyMacroPoint(meal.carbsG)
                        meal.carbsLowG = carbs
                        meal.carbsLikelyG = carbs
                        meal.carbsHighG = carbs
                        meal.sourceActionKey = "legacy-meal-\(meal.id.uuidString.lowercased())"
                        meal.evidenceData = try encoder.encode(Self.legacyMealEvidence(
                            id: meal.id,
                            algorithmVersion: meal.algorithmVersion,
                            energyIsAvailable: legacyEnergy != nil
                        ))

                        for dish in meal.dishes {
                            let legacyDishEnergy = Self.legacyEnergyPoint(dish.estimatedCaloriesKcal)
                            let dishEnergy = legacyDishEnergy ?? 0
                            dish.id = UUID()
                            dish.energyLowKcal = dishEnergy
                            dish.energyLikelyKcal = dishEnergy
                            dish.energyHighKcal = dishEnergy
                            let protein = Self.legacyMacroPoint(dish.estimatedProteinG)
                            dish.proteinLowG = protein
                            dish.proteinLikelyG = protein
                            dish.proteinHighG = protein
                            let fat = Self.legacyMacroPoint(dish.estimatedFatG)
                            dish.fatLowG = fat
                            dish.fatLikelyG = fat
                            dish.fatHighG = fat
                            let carbs = Self.legacyMacroPoint(dish.estimatedCarbsG)
                            dish.carbsLowG = carbs
                            dish.carbsLikelyG = carbs
                            dish.carbsHighG = carbs
                            dish.evidenceData = try encoder.encode(Self.legacyMealEvidence(
                                id: dish.id ?? UUID(),
                                algorithmVersion: meal.algorithmVersion,
                                energyIsAvailable: legacyDishEnergy != nil
                            ))
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
            .custom(
                fromVersion: DensosoSchemaV4.self,
                toVersion: DensosoSchemaV5.self,
                willMigrate: { context in
                    let currentProjectionVersion = AlgorithmVersions.dailyMetricsProjection
                    let metrics = try context.fetch(FetchDescriptor<DensosoSchemaV4.DailyMetrics>())
                    for metric in metrics
                    where metric.projectionVersion != currentProjectionVersion
                        || metric.sourceFingerprint.isEmpty {
                        metric.requiresRecompute = true
                    }
                    try context.save()
                },
                didMigrate: nil
            ),
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
                        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
                        return (record, snapshot, Self.historicalCalendar(for: snapshot.timezoneIdentifier))
                    }
                    var existingDayKeys = Set(records.map(\.dayKey))
                    var uniqueSamples: [UUID: (sample: HealthSampleSnapshot, calendar: Calendar)] = [:]
                    for (_, snapshot, calendar) in decodedSnapshots {
                        let orderedSamples = (snapshot.healthKitSamples ?? []).sorted(
                            by: HealthSampleSnapshot.stableDeduplicationOrder
                        )
                        for sample in orderedSamples {
                            if let existing = uniqueSamples[sample.id] {
                                if HealthSampleSnapshot.preferredForDeduplication(sample, over: existing.sample) {
                                    uniqueSamples[sample.id] = (sample, calendar)
                                }
                            } else {
                                uniqueSamples[sample.id] = (sample, calendar)
                            }
                        }
                    }
                    var samplesByDayKey: [String: [UUID: HealthSampleSnapshot]] = [:]
                    for (sampleID, located) in uniqueSamples {
                        let sampleDay = located.calendar.startOfDay(for: located.sample.startDate)
                        let sampleDayKey = Self.dayKey(for: sampleDay, calendar: located.calendar)
                        let sampleBucketKey = Self.snapshotBucketKey(dayKey: sampleDayKey, calendar: located.calendar)
                        samplesByDayKey[sampleBucketKey, default: [:]][sampleID] = located.sample
                        locationsBySampleID[sampleID] = (
                            located.sample.metric.rawValue,
                            sampleDayKey,
                            located.sample.startDate,
                            located.sample.endDate
                        )
                    }
                    for (record, snapshot, calendar) in decodedSnapshots {
                        let day = calendar.startOfDay(for: snapshot.dayStart)
                        let snapshotBucketKey = Self.snapshotBucketKey(dayKey: record.dayKey, calendar: calendar)
                        let samples = (samplesByDayKey[snapshotBucketKey] ?? [:]).values.sorted(
                            by: HealthSampleSnapshot.stableDeduplicationOrder
                        )
                        let dayWorkouts = workouts.filter {
                            calendar.startOfDay(for: $0.date) == day
                        }
                        let previousDay = calendar.date(byAdding: .day, value: -1, to: day)
                        let previousDayKey = previousDay.map {
                            Self.snapshotBucketKey(dayKey: Self.dayKey(for: $0, calendar: calendar), calendar: calendar)
                        }
                        let previousSleepSamples = previousDayKey.flatMap { samplesByDayKey[$0] }
                            .map { Array($0.values) } ?? []
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

                    var sleepSamplesByWakeDay: [String: (date: Date, dayKey: String, calendar: Calendar, samples: [HealthSampleSnapshot])] = [:]
                    for sampleID in uniqueSamples.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                        guard let located = uniqueSamples[sampleID],
                              located.sample.metric == .sleepAnalysis else { continue }
                        for wakeDay in Self.sleepWakeDays(
                            startDate: located.sample.startDate,
                            endDate: located.sample.endDate,
                            calendar: located.calendar
                        ) {
                            let wakeDayKey = Self.dayKey(for: wakeDay, calendar: located.calendar)
                            let bucketKey = Self.snapshotBucketKey(dayKey: wakeDayKey, calendar: located.calendar)
                            if sleepSamplesByWakeDay[bucketKey] == nil {
                                sleepSamplesByWakeDay[bucketKey] = (wakeDay, wakeDayKey, located.calendar, [])
                            }
                            sleepSamplesByWakeDay[bucketKey]?.samples.append(located.sample)
                        }
                    }
                    for bucketKey in sleepSamplesByWakeDay.keys.sorted() {
                        guard let wakeDayEntry = sleepSamplesByWakeDay[bucketKey],
                              existingDayKeys.insert(wakeDayEntry.dayKey).inserted else { continue }
                        let wakeDay = wakeDayEntry.date
                        let wakeSamples = wakeDayEntry.samples.sorted(
                            by: HealthSampleSnapshot.stableDeduplicationOrder
                        )
                        let summary = DailyHealthSampleSummary(
                            samples: [],
                            dayStart: wakeDay,
                            sleepSamples: wakeSamples
                        )
                        let cacheOnlySnapshot = DailyHealthSnapshot(
                            dayStart: wakeDay,
                            timezoneIdentifier: wakeDayEntry.calendar.timeZone.identifier,
                            healthKitSampleSummary: summary,
                            healthReadStates: [HealthMetricID.sleepAnalysis.rawValue: .available],
                            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
                        )
                        let payloadData = try encoder.encode(cacheOnlySnapshot)
                        context.insert(DensosoSchemaV4.DailyHealthSnapshotRecord(
                            dayKey: wakeDayEntry.dayKey,
                            timezoneID: cacheOnlySnapshot.timezoneIdentifier,
                            payloadData: payloadData,
                            snapshotHash: SHA256.hash(data: payloadData)
                                .map { String(format: "%02x", $0) }
                                .joined(),
                            algorithmVersion: cacheOnlySnapshot.algorithmVersion
                        ))
                    }

                    for (sampleID, location) in locationsBySampleID {
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
            .lightweight(fromVersion: DensosoSchemaV6.self, toVersion: DensosoSchemaV7.self),
            .lightweight(fromVersion: DensosoSchemaV7.self, toVersion: DensosoSchemaV8.self),
            .lightweight(fromVersion: DensosoSchemaV8.self, toVersion: DensosoSchemaV9.self),
            .lightweight(fromVersion: DensosoSchemaV9.self, toVersion: DensosoSchemaV10.self),
            .lightweight(fromVersion: DensosoSchemaV10.self, toVersion: DensosoSchemaV11.self),
            .lightweight(fromVersion: DensosoSchemaV11.self, toVersion: DensosoSchemaV12.self),
            .lightweight(fromVersion: DensosoSchemaV12.self, toVersion: DensosoSchemaV13.self),
            .lightweight(fromVersion: DensosoSchemaV13.self, toVersion: DensosoSchemaV14.self),
            .custom(
                fromVersion: DensosoSchemaV14.self,
                toVersion: DensosoSchemaV15.self,
                willMigrate: nil,
                didMigrate: { context in
                    try ConfirmedPlanSessionIndexRepository.rebuild(in: context)
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

    private static func historicalCalendar(for timezoneIdentifier: String) -> Calendar {
        var calendar = Calendar.current
        guard let timeZone = TimeZone(identifier: timezoneIdentifier) else {
            NSLog("Densoso migration V5->V6: invalid historical timezone '%@'; falling back to current timezone.", timezoneIdentifier)
            return calendar
        }
        calendar.timeZone = timeZone
        return calendar
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func snapshotBucketKey(dayKey: String, calendar: Calendar) -> String {
        "\(calendar.timeZone.identifier)|\(dayKey)"
    }

    private static func sleepWakeDays(startDate: Date, endDate: Date, calendar: Calendar) -> Set<Date> {
        guard startDate.timeIntervalSince1970.isFinite,
              endDate.timeIntervalSince1970.isFinite,
              endDate > startDate else { return [] }
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

    /// V2 used zero as the default for missing macros, so only positive finite legacy
    /// values can safely become point estimates. Keep zero and invalid values unavailable.
    private static func legacyMacroPoint(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    /// V2 used zero as the default for missing meal energy, so zero cannot safely
    /// become a historical point estimate. The current V3 compatibility columns are
    /// nonoptional, so unavailable energy remains encoded as a zero sentinel plus
    /// explicit unresolved evidence; presentation and read models must honor it.
    private static func legacyEnergyPoint(_ value: Int) -> Double? {
        guard value > 0 else { return nil }
        return Double(value)
    }

    private static func legacyMealEvidence(
        id: UUID,
        algorithmVersion: String,
        energyIsAvailable: Bool
    ) -> [EvidenceSnapshot] {
        let legacyEvidence = EvidenceSnapshot(
            id: id,
            grade: .legacyPointEstimate,
            sourceID: "swiftdata-v2",
            sourceVersion: algorithmVersion,
            summary: energyIsAvailable
                ? "Migrated without recalculating the historical point estimate."
                : "Historical energy is unavailable; V2's default zero cannot prove zero kcal."
        )
        guard !energyIsAvailable else { return [legacyEvidence] }
        return [
            legacyEvidence,
            EvidenceSnapshot(
                grade: .unresolved,
                sourceID: "legacy-v2-default-zero-energy",
                sourceVersion: "swiftdata-v2",
                summary: "V2 stored zero both for missing energy and explicit values; treat this zero as unavailable."
            ),
        ]
    }
}

private struct LegacyProfileWeightEntry: Decodable {
    let date: Date
    let kg: Double
}
