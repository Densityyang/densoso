import Foundation
import SwiftData
import DensosoDomain

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
        let profileKey = try modelContext.fetch(FetchDescriptor<UserProfile>()).first?.profileKey ?? "primary"
        let revisionRecords = try modelContext.fetch(FetchDescriptor<ProfileRevisionRecord>())
        let revisions = revisionRecords.map(domainRevision)
        let effectiveProfile = EffectiveProfileResolver(profileKey: profileKey, revisions: revisions).profile(at: day)
        let effectiveRevision = revisionRecords
            .filter { $0.profileKey == profileKey && $0.effectiveFrom <= day }
            .sorted {
                if $0.effectiveFrom != $1.effectiveFrom { return $0.effectiveFrom < $1.effectiveFrom }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .last
        let weightObservations = try localWeightObservations(in: modelContext)
            + healthKitWeightObservations(in: modelContext)
        let effectiveWeight = WeightTimeline(observations: weightObservations).effectiveWeight(
            at: day,
            profileWeightKg: effectiveRevision?.weightKg,
            profileEffectiveFrom: effectiveRevision?.effectiveFrom
        )
        let healthSnapshot = try healthSnapshot(for: day, in: modelContext)
        let projected = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: meals,
            workouts: workouts,
            effectiveProfile: effectiveProfile,
            effectiveWeight: effectiveWeight,
            healthKitActiveEnergyKcal: healthSnapshot?.activeEnergyForProjection,
            healthKitRestingEnergyKcal: healthSnapshot?.restingEnergyForProjection,
            healthKitSteps: healthSnapshot?.stepCountForProjection,
            healthKitExerciseMinutes: healthSnapshot?.exerciseMinutesForProjection
        )

        let metricPredicate = #Predicate<DailyMetrics> { $0.date == day }
        if let existing = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: metricPredicate)).first {
            copy(projected, to: existing)
        } else {
            modelContext.insert(projected)
        }
    }

    private static func domainRevision(_ record: ProfileRevisionRecord) -> ProfileRevision {
        ProfileRevision(
            id: record.id,
            profileKey: record.profileKey,
            effectiveFrom: record.effectiveFrom,
            dateOfBirth: record.dateOfBirth,
            biologicalSex: BiologicalSex(rawValue: record.biologicalSex) ?? .unspecified,
            heightCm: record.heightCm,
            weightKg: record.weightKg,
            activityLevel: ActivityLevel(rawValue: record.activityLevel) ?? .unspecified,
            source: ProfileSource(rawValue: record.source) ?? .legacyMigration,
            createdAt: record.createdAt
        )
    }

    private static func localWeightObservations(in modelContext: ModelContext) throws -> [WeightObservation] {
        try modelContext.fetch(FetchDescriptor<WeightRecord>()).compactMap { record in
            guard let source = WeightSource(rawValue: record.source) else { return nil }
            return WeightObservation(
                id: record.id,
                measuredAt: record.measuredAt,
                kilograms: record.kilograms,
                source: source,
                confidence: record.confidence,
                healthKitSyncIdentifier: record.healthKitSyncIdentifier
            )
        }
    }

    private static func healthKitWeightObservations(in modelContext: ModelContext) throws -> [WeightObservation] {
        let records = try modelContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return records.flatMap { record -> [WeightObservation] in
            guard let snapshot = try? decoder.decode(DailyHealthSnapshot.self, from: record.payloadData) else {
                return []
            }
            return (snapshot.healthKitSamples ?? []).compactMap { sample in
                guard sample.metric == .bodyMass,
                      let kilograms = sample.value,
                      kilograms.isFinite,
                      kilograms > 0
                else {
                    return nil
                }
                return WeightObservation(
                    id: sample.id,
                    measuredAt: sample.endDate,
                    kilograms: kilograms,
                    source: .healthKit,
                    confidence: 1,
                    healthKitSyncIdentifier: sample.syncIdentifier
                )
            }
        }
    }

    private static func healthSnapshot(for day: Date, in modelContext: ModelContext) throws -> DailyHealthSnapshot? {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        guard let record = try modelContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
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
        destination.intakeEnergyLowKcal = source.intakeEnergyLowKcal
        destination.intakeEnergyLikelyKcal = source.intakeEnergyLikelyKcal
        destination.intakeEnergyHighKcal = source.intakeEnergyHighKcal
        destination.expenditureEnergyLowKcal = source.expenditureEnergyLowKcal
        destination.expenditureEnergyLikelyKcal = source.expenditureEnergyLikelyKcal
        destination.expenditureEnergyHighKcal = source.expenditureEnergyHighKcal
        destination.energyBalanceLowKcal = source.energyBalanceLowKcal
        destination.energyBalanceLikelyKcal = source.energyBalanceLikelyKcal
        destination.energyBalanceHighKcal = source.energyBalanceHighKcal
        destination.activeEnergyKcal = source.activeEnergyKcal
        destination.basalEnergyKcal = source.basalEnergyKcal
        destination.steps = source.steps
        destination.exerciseMinutes = source.exerciseMinutes
        destination.weightKg = source.weightKg
        destination.energyQuality = source.energyQuality
        destination.dataCoverageJSON = source.dataCoverageJSON
        destination.projectionVersion = source.projectionVersion
        destination.sourceFingerprint = source.sourceFingerprint
        destination.requiresRecompute = source.requiresRecompute
    }
}
