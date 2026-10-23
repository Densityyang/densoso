import Foundation
import SwiftData
import DensosoDomain

/// The sole projection path from health records to their daily aggregate.
enum DailyMetricsProjectionError: Equatable, Sendable, SharedErrorDescribing {
    case failed

    var sharedErrorDescriptor: SharedErrorDescriptor {
        SharedErrorDescriptor(
            code: .projectionFailed,
            userMessage: "暂时没能更新今天的状态。",
            subsystem: .projection,
            reason: .dailyMetricsProjectionFailed
        )
    }

    var errorDescription: String? { sharedErrorDescriptor.userMessage }
}

@MainActor
enum DailyMetricsProjector {
    static func reproject(on date: Date, now: Date = Date(), in modelContext: ModelContext) throws {
        try withProjectionErrorMapping {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: date)
            let asOf = HistoricalMetricsEligibilityPolicy.referenceDate(for: day, now: now, calendar: calendar)
            let metricPredicate = #Predicate<DailyMetrics> { $0.date == day }
            let existing = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: metricPredicate)).first
            let effectiveInputs = try resolveEffectiveInputs(on: day, asOf: asOf, in: modelContext)
            let projectionInputs = try DailyMetricsProjectionInputReader.read(on: day, in: modelContext)
            let healthSnapshot = try healthSnapshot(for: day, in: modelContext)
            let fingerprintContext = try DailyMetricsProjectionFingerprint.context(
                on: day,
                asOf: asOf,
                inputs: projectionInputs,
                profileRevision: effectiveInputs.profileRevision,
                weightObservations: effectiveInputs.weightObservations,
                in: modelContext
            )
            let expectedFingerprint = CaloricEngine.projectionFingerprint(
                day: day,
                meals: projectionInputs.meals,
                workouts: projectionInputs.workouts,
                profile: effectiveInputs.profile,
                weight: effectiveInputs.weight,
                activeEnergy: healthSnapshot?.activeEnergyForProjection,
                basalEnergy: healthSnapshot?.restingEnergyForProjection,
                steps: healthSnapshot?.stepCountForProjection,
                exerciseMinutes: healthSnapshot?.exerciseMinutesForProjection,
                context: fingerprintContext
            )
            let historicalInputsMissing = day < calendar.startOfDay(for: now)
                && !HistoricalMetricsEligibilityPolicy.hasValidInputs(
                    profile: effectiveInputs.profile,
                    weight: effectiveInputs.weight,
                    asOf: asOf,
                    calendar: calendar
                )
            if let existing,
               DailyMetricsProjectionFingerprint.sourceMatches(
                   storedFingerprint: existing.sourceFingerprint,
                   storedAlgorithmVersion: existing.projectionVersion,
                   expectedFingerprint: expectedFingerprint,
                   expectedAlgorithmVersion: fingerprintContext.algorithmVersion
               ) {
                if historicalInputsMissing && existing.requiresRecompute {
                    HistoricalMetricsEligibilityPolicy.markPendingIfHistoricalInputsAreMissing(
                        existing,
                        on: day,
                        now: now,
                        profile: effectiveInputs.profile,
                        weight: effectiveInputs.weight,
                        calendar: calendar
                    )
                    return
                }
                if !historicalInputsMissing && !existing.requiresRecompute { return }
            }
            let projected = makeProjection(
                on: day,
                effectiveInputs: effectiveInputs,
                projectionInputs: projectionInputs,
                healthSnapshot: healthSnapshot,
                fingerprintContext: fingerprintContext
            )
            HistoricalMetricsEligibilityPolicy.markPendingIfHistoricalInputsAreMissing(
                projected,
                on: day,
                now: now,
                profile: effectiveInputs.profile,
                weight: effectiveInputs.weight,
                calendar: calendar
            )

            if let existing {
                copy(projected, to: existing)
            } else {
                modelContext.insert(projected)
            }
        }
    }

    static func hasValidHistoricalRecomputeInputs(
        on date: Date,
        now: Date = Date(),
        in modelContext: ModelContext
    ) throws -> Bool {
        try withProjectionErrorMapping {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: date)
            guard try hasPendingMetric(on: day, in: modelContext) else { return false }
            let asOf = HistoricalMetricsEligibilityPolicy.referenceDate(for: day, now: now, calendar: calendar)
            let effectiveInputs = try resolveEffectiveInputs(on: day, asOf: asOf, in: modelContext)
            return HistoricalMetricsEligibilityPolicy.hasValidInputs(
                profile: effectiveInputs.profile,
                weight: effectiveInputs.weight,
                asOf: asOf,
                calendar: calendar
            )
        }
    }

    @discardableResult
    static func reprojectHistoricalIfInputsAvailable(
        on date: Date,
        now: Date = Date(),
        in modelContext: ModelContext
    ) throws -> Bool {
        try withProjectionErrorMapping {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: date)
            let metricPredicate = #Predicate<DailyMetrics> { $0.date == day }
            guard let existing = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: metricPredicate)).first,
                  isHistoricalRecomputeCandidate(existing) else { return false }

            let asOf = HistoricalMetricsEligibilityPolicy.referenceDate(for: day, now: now, calendar: calendar)
            let effectiveInputs = try resolveEffectiveInputs(on: day, asOf: asOf, in: modelContext)
            guard HistoricalMetricsEligibilityPolicy.hasValidInputs(
                profile: effectiveInputs.profile,
                weight: effectiveInputs.weight,
                asOf: asOf,
                calendar: calendar
            ) else { return false }

            let projectionInputs = try DailyMetricsProjectionInputReader.read(on: day, in: modelContext)
            let healthSnapshot = try healthSnapshot(for: day, in: modelContext)
            let fingerprintContext = try DailyMetricsProjectionFingerprint.context(
                on: day,
                asOf: asOf,
                inputs: projectionInputs,
                profileRevision: effectiveInputs.profileRevision,
                weightObservations: effectiveInputs.weightObservations,
                in: modelContext
            )
            let projected = makeProjection(
                on: day,
                effectiveInputs: effectiveInputs,
                projectionInputs: projectionInputs,
                healthSnapshot: healthSnapshot,
                fingerprintContext: fingerprintContext
            )
            copy(projected, to: existing)
            return true
        }
    }

    private static func withProjectionErrorMapping<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch {
            throw DailyMetricsProjectionError.failed
        }
    }

    private struct EffectiveProjectionInputs {
        let profile: EffectiveProfile?
        let weight: EffectiveWeight?
        let profileRevision: ProfileRevisionRecord?
        let weightObservations: [WeightObservation]
    }

    private static func hasPendingMetric(on day: Date, in modelContext: ModelContext) throws -> Bool {
        let currentProjectionVersion = AlgorithmVersions.dailyMetricsProjection
        let emptyFingerprint = ""
        let predicate = #Predicate<DailyMetrics> {
            $0.date == day
                && ($0.requiresRecompute
                    || $0.projectionVersion != currentProjectionVersion
                    || $0.sourceFingerprint == emptyFingerprint)
        }
        var descriptor = FetchDescriptor<DailyMetrics>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first != nil
    }

    private static func isHistoricalRecomputeCandidate(_ metrics: DailyMetrics) -> Bool {
        metrics.requiresRecompute
            || metrics.projectionVersion != AlgorithmVersions.dailyMetricsProjection
            || metrics.sourceFingerprint.isEmpty
    }

    private static func resolveEffectiveInputs(
        on day: Date,
        asOf referenceDate: Date,
        in modelContext: ModelContext
    ) throws -> EffectiveProjectionInputs {
        let primaryProfileKey = "primary"
        let profilePredicate = #Predicate<UserProfile> { $0.profileKey == primaryProfileKey }
        var profileDescriptor = FetchDescriptor<UserProfile>(predicate: profilePredicate)
        profileDescriptor.fetchLimit = 1
        let profileKey = try modelContext.fetch(profileDescriptor).first?.profileKey ?? primaryProfileKey
        let effectiveRevision = try EffectiveProfileRevisionReader.latest(
            in: modelContext,
            profileKey: profileKey,
            effectiveAt: referenceDate
        )
        let effectiveProfile: EffectiveProfile?
        if let effectiveRevision {
            effectiveProfile = EffectiveProfileResolver(
                profileKey: profileKey,
                revisions: [domainRevision(effectiveRevision)]
            ).profile(at: referenceDate)
        } else {
            effectiveProfile = nil
        }
        let localWeight = try LocalWeightObservationReader.latestObservation(in: modelContext, effectiveAt: referenceDate)
        let healthKitWeight = try HealthKitWeightObservationReader.latestObservation(in: modelContext, effectiveAt: referenceDate)
        let weightObservations = [localWeight, healthKitWeight].compactMap { $0 }
        let effectiveWeight = WeightTimeline(observations: weightObservations).effectiveWeight(
            at: referenceDate,
            profileWeightKg: effectiveRevision?.weightKg,
            profileEffectiveFrom: effectiveRevision?.effectiveFrom
        )
        return EffectiveProjectionInputs(
            profile: effectiveProfile,
            weight: effectiveWeight,
            profileRevision: effectiveRevision,
            weightObservations: weightObservations
        )
    }

    private static func makeProjection(
        on day: Date,
        effectiveInputs: EffectiveProjectionInputs,
        projectionInputs: DailyMetricsProjectionInputs,
        healthSnapshot: DailyHealthSnapshot?,
        fingerprintContext: DailyMetricsProjectionFingerprintContext
    ) -> DailyMetrics {
        CaloricEngine.computeDailyMetrics(
            date: day,
            meals: projectionInputs.meals,
            workouts: projectionInputs.workouts,
            effectiveProfile: effectiveInputs.profile,
            effectiveWeight: effectiveInputs.weight,
            healthKitActiveEnergyKcal: healthSnapshot?.activeEnergyForProjection,
            healthKitRestingEnergyKcal: healthSnapshot?.restingEnergyForProjection,
            healthKitSteps: healthSnapshot?.stepCountForProjection,
            healthKitExerciseMinutes: healthSnapshot?.exerciseMinutesForProjection,
            fingerprintContext: fingerprintContext
        )
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

    private static func healthKitWeightObservations(
        in modelContext: ModelContext,
        effectiveAt day: Date
    ) throws -> [WeightObservation] {
        try HealthKitWeightObservationReader.latestObservation(in: modelContext, effectiveAt: day)
            .map { [$0] } ?? []
    }

    private static func healthSnapshot(for day: Date, in modelContext: ModelContext) throws -> DailyHealthSnapshot? {
        guard let record = try healthSnapshotRecord(for: day, in: modelContext) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
    }

    private static func healthSnapshotRecord(
        for day: Date,
        in modelContext: ModelContext
    ) throws -> DailyHealthSnapshotRecord? {
        let targetDayKey = dayKey(for: day)
        let predicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == targetDayKey }
        var descriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func dayKey(for day: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
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
