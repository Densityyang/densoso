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
enum DailyMetricsProjectionWriteGate {
    struct Lease: Equatable {
        fileprivate let storeKey: ObjectIdentifier
        fileprivate let ownerID: UUID
        fileprivate let lockKeys: Set<String>
    }

    private struct Waiter {
        let id: UUID
        let lockKeys: Set<String>
        let continuation: CheckedContinuation<Lease?, Never>
    }

    private struct WaiterCountObserver {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private static let storeWideKey = "*"
    private static var heldContexts: [ObjectIdentifier: [String: UUID]] = [:]
    private static var waiters: [ObjectIdentifier: [Waiter]] = [:]
    private static var waiterCountObservers: [ObjectIdentifier: [WaiterCountObserver]] = [:]

    static func withLock<T>(
        for modelContext: ModelContext,
        dayKeys: Set<String>? = nil,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        try await withLockAndLease(for: modelContext, dayKeys: dayKeys) { _ in try await operation() }
    }

    static func withLockAndLease<T>(
        for modelContext: ModelContext,
        dayKeys: Set<String>? = nil,
        operation: @MainActor (Lease) async throws -> T
    ) async throws -> T {
        let lease = try await acquire(storeID: ObjectIdentifier(modelContext.container), dayKeys: dayKeys)
        defer { release(lease) }
        try Task.checkCancellation()
        return try await operation(lease)
    }

    /// A nil day-key set requests a store-wide lease. Day-scoped leases let
    /// independent daily projections proceed concurrently.
    static func acquire(storeID key: ObjectIdentifier, dayKeys: Set<String>? = nil) async throws -> Lease {
        try Task.checkCancellation()
        let requestedKeys = normalizedLockKeys(dayKeys)
        if canGrant(requestedKeys, storeID: key), !hasEarlierConflictingWaiter(requestedKeys, storeID: key) {
            let lease = Lease(storeKey: key, ownerID: UUID(), lockKeys: requestedKeys)
            hold(lease)
            return lease
        }

        let waiterID = UUID()
        let lease = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Lease?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                waiters[key, default: []].append(Waiter(id: waiterID, lockKeys: requestedKeys, continuation: continuation))
                notifyWaiterCountObservers(for: key)
            }
        } onCancel: {
            Task { @MainActor in
                cancelWaiter(waiterID, for: key)
            }
        }
        guard let lease else { throw CancellationError() }
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    static func release(_ lease: Lease) {
        guard let held = heldContexts[lease.storeKey],
              lease.lockKeys.allSatisfy({ held[$0] == lease.ownerID }) else { return }
        var updated = held
        for lockKey in lease.lockKeys { updated[lockKey] = nil }
        heldContexts[lease.storeKey] = updated.isEmpty ? nil : updated
        grantNextWaiter(for: lease.storeKey)
    }

    static func validate(_ lease: Lease, storeID: ObjectIdentifier, dayKeys: Set<String>? = nil) throws {
        guard lease.storeKey == storeID,
              let held = heldContexts[storeID],
              lease.lockKeys.allSatisfy({ held[$0] == lease.ownerID }) else {
            throw DailyMetricsProjectionGateError.invalidLease
        }
        if let dayKeys, !dayKeys.isSubset(of: lease.lockKeys) {
            throw DailyMetricsProjectionGateError.invalidLease
        }
    }

    nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(calendar.timeZone.identifier)|\(String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0))"
    }

    static func waitUntilWaitingCount(_ count: Int, storeID key: ObjectIdentifier) async {
        guard (waiters[key]?.count ?? 0) != count else { return }
        await withCheckedContinuation { continuation in
            if (waiters[key]?.count ?? 0) == count {
                continuation.resume()
            } else {
                waiterCountObservers[key, default: []].append(
                    WaiterCountObserver(expectedCount: count, continuation: continuation)
                )
            }
        }
    }

    private static func cancelWaiter(_ id: UUID, for key: ObjectIdentifier) {
        guard var contextWaiters = waiters[key],
              let index = contextWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = contextWaiters.remove(at: index)
        waiters[key] = contextWaiters.isEmpty ? nil : contextWaiters
        notifyWaiterCountObservers(for: key)
        waiter.continuation.resume(returning: nil)
        if heldContexts[key]?.isEmpty != false {
            grantNextWaiter(for: key)
        }
    }

    private static func grantNextWaiter(for key: ObjectIdentifier) {
        guard var contextWaiters = waiters[key], !contextWaiters.isEmpty else { return }
        var grantedAny = true
        while grantedAny {
            grantedAny = false
            for index in contextWaiters.indices {
                let waiter = contextWaiters[index]
                guard canGrant(waiter.lockKeys, storeID: key),
                      !contextWaiters[..<index].contains(where: { keysConflict($0.lockKeys, waiter.lockKeys) }) else {
                    continue
                }
                contextWaiters.remove(at: index)
                waiters[key] = contextWaiters.isEmpty ? nil : contextWaiters
                let lease = Lease(storeKey: key, ownerID: UUID(), lockKeys: waiter.lockKeys)
                hold(lease)
                waiter.continuation.resume(returning: lease)
                contextWaiters = waiters[key] ?? []
                notifyWaiterCountObservers(for: key)
                grantedAny = true
                break
            }
        }
    }

    private static func normalizedLockKeys(_ dayKeys: Set<String>?) -> Set<String> {
        guard let dayKeys, !dayKeys.isEmpty else { return [storeWideKey] }
        return dayKeys
    }

    private static func hold(_ lease: Lease) {
        var held = heldContexts[lease.storeKey, default: [:]]
        for key in lease.lockKeys { held[key] = lease.ownerID }
        heldContexts[lease.storeKey] = held
    }

    private static func canGrant(_ keys: Set<String>, storeID: ObjectIdentifier) -> Bool {
        !keysConflict(keys, Set(heldContexts[storeID, default: [:]].keys))
    }

    private static func hasEarlierConflictingWaiter(_ keys: Set<String>, storeID: ObjectIdentifier) -> Bool {
        waiters[storeID, default: []].contains { keysConflict($0.lockKeys, keys) }
    }

    private static func keysConflict(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        lhs.contains(storeWideKey) || rhs.contains(storeWideKey) || !lhs.isDisjoint(with: rhs)
    }

    private static func notifyWaiterCountObservers(for key: ObjectIdentifier) {
        let count = waiters[key]?.count ?? 0
        guard let observers = waiterCountObservers[key], !observers.isEmpty else { return }
        var pending: [WaiterCountObserver] = []
        for observer in observers {
            if observer.expectedCount == count {
                observer.continuation.resume()
            } else {
                pending.append(observer)
            }
        }
        waiterCountObservers[key] = pending.isEmpty ? nil : pending
    }
}

enum DailyMetricsProjectionGateError: Error {
    case invalidLease
}

private struct ExistingMetricProjectionSnapshot: Sendable {
    let sourceFingerprint: String
    let projectionVersion: String
    let requiresRecompute: Bool
}

private struct DailyMetricsProjectionSnapshot: Sendable {
    let calculationInput: DailyMetricsCalculationInput
    let historicalInputsMissing: Bool
    let existing: ExistingMetricProjectionSnapshot?
    let effectiveProfile: EffectiveProfile?
    let effectiveWeight: EffectiveWeight?
}

@MainActor
enum DailyMetricsProjector {

    private static func projectionSnapshot(
        on date: Date,
        now: Date,
        calendar: Calendar,
        in modelContext: ModelContext
    ) throws -> DailyMetricsProjectionSnapshot {
        let day = calendar.startOfDay(for: date)
        let asOf = HistoricalMetricsEligibilityPolicy.referenceDate(for: day, now: now, calendar: calendar)
        let existing = try existingMetric(on: day, in: modelContext).map {
            ExistingMetricProjectionSnapshot(
                sourceFingerprint: $0.sourceFingerprint,
                projectionVersion: $0.projectionVersion,
                requiresRecompute: $0.requiresRecompute
            )
        }
        let effectiveInputs = try resolveEffectiveInputs(on: day, asOf: asOf, in: modelContext)
        let projectionInputs = try DailyMetricsProjectionInputReader.read(
            on: day,
            calendar: calendar,
            in: modelContext
        )
        let healthSnapshot = try healthSnapshot(for: day, calendar: calendar, in: modelContext)
        let fingerprintContext = try DailyMetricsProjectionFingerprint.context(
            on: day,
            calendar: calendar,
            asOf: asOf,
            inputs: projectionInputs,
            profileRevision: effectiveInputs.profileRevision,
            weightObservations: effectiveInputs.weightObservations,
            in: modelContext
        )
        let calculationInput = CaloricEngine.calculationInput(
            date: day,
            calendar: calendar,
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
        let historicalInputsMissing = day < calendar.startOfDay(for: now)
            && !HistoricalMetricsEligibilityPolicy.hasValidInputs(
                profile: effectiveInputs.profile,
                weight: effectiveInputs.weight,
                asOf: asOf,
                calendar: calendar
            )
        return DailyMetricsProjectionSnapshot(
            calculationInput: calculationInput,
            historicalInputsMissing: historicalInputsMissing,
            existing: existing,
            effectiveProfile: effectiveInputs.profile,
            effectiveWeight: effectiveInputs.weight
        )
    }

    private static func existingMetric(on day: Date, in modelContext: ModelContext) throws -> DailyMetrics? {
        let metricPredicate = #Predicate<DailyMetrics> { $0.date == day }
        return try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: metricPredicate)).first
    }

/// Serializes DailyMetrics source mutations and projections across every
/// ModelContext backed by the same ModelContainer. The lock remains held while
/// detached pure calculation runs, but no ModelContext enters that calculation.
    static func reproject(on date: Date, now: Date = Date(), in modelContext: ModelContext) async throws {
        try await DailyMetricsProjectionWriteGate.withLock(
            for: modelContext,
            dayKeys: [DailyMetricsProjectionWriteGate.dayKey(for: date)]
        ) {
            try Task.checkCancellation()
            try await reprojectWhileGateHeld(on: date, now: now, in: modelContext)
        }
    }

    /// Used by HealthRepository after it has acquired the same context gate for
    /// the source mutation, so the source and projection cannot interleave with
    /// another repository write.
    static func reprojectWhileGateHeld(
        on date: Date,
        now: Date = Date(),
        in modelContext: ModelContext
    ) async throws {
        try await withProjectionErrorMapping {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: date)

            // Re-read after calculation and retry if another writer changed any
            // source input while the detached task was running. The gate covers
            // repository/projector writes; this validation also protects callers
            // that share the context through another coordinated path.
            for _ in 0..<3 {
                let snapshot = try projectionSnapshot(on: day, now: now, calendar: calendar, in: modelContext)
                let expectedFingerprint = await Task.detached(priority: .utility) {
                    DailyMetricsProjectionCalculator.fingerprint(for: snapshot.calculationInput)
                }.value

                if let existing = snapshot.existing,
                   DailyMetricsProjectionFingerprint.sourceMatches(
                       storedFingerprint: existing.sourceFingerprint,
                       storedAlgorithmVersion: existing.projectionVersion,
                       expectedFingerprint: expectedFingerprint,
                       expectedAlgorithmVersion: snapshot.calculationInput.fingerprintContext.algorithmVersion
                   ) {
                    let metric = try existingMetric(on: day, in: modelContext)
                    if snapshot.historicalInputsMissing && metric?.requiresRecompute == true {
                        if let metric {
                            HistoricalMetricsEligibilityPolicy.markPendingIfHistoricalInputsAreMissing(
                                metric,
                                on: day,
                                now: now,
                                profile: snapshot.effectiveProfile,
                                weight: snapshot.effectiveWeight,
                                calendar: calendar
                            )
                        }
                        return
                    }
                    if !snapshot.historicalInputsMissing && metric?.requiresRecompute == false { return }
                }

                let calculationResult = await Task.detached(priority: .utility) {
                    DailyMetricsProjectionCalculator.calculate(
                        snapshot.calculationInput,
                        sourceFingerprint: expectedFingerprint
                    )
                }.value

                let currentSnapshot = try projectionSnapshot(on: day, now: now, calendar: calendar, in: modelContext)
                let currentFingerprint = await Task.detached(priority: .utility) {
                    DailyMetricsProjectionCalculator.fingerprint(for: currentSnapshot.calculationInput)
                }.value
                guard currentFingerprint == expectedFingerprint else { continue }

                let projected = calculationResult.makeDailyMetrics()
                HistoricalMetricsEligibilityPolicy.markPendingIfHistoricalInputsAreMissing(
                    projected,
                    on: day,
                    now: now,
                    profile: currentSnapshot.effectiveProfile,
                    weight: currentSnapshot.effectiveWeight,
                    calendar: calendar
                )

                if let existing = try existingMetric(on: day, in: modelContext) {
                    copy(projected, to: existing)
                } else {
                    modelContext.insert(projected)
                }
                return
            }

            throw DailyMetricsProjectionError.failed
        }
    }

    static func markPendingForReprojectionWhileGateHeld(on date: Date, in modelContext: ModelContext) throws {
        let day = Calendar.current.startOfDay(for: date)
        if let metric = try existingMetric(on: day, in: modelContext) {
            metric.requiresRecompute = true
        } else {
            modelContext.insert(DailyMetrics(
                date: day,
                projectionVersion: AlgorithmVersions.dailyMetricsProjection,
                sourceFingerprint: "",
                requiresRecompute: true
            ))
        }
    }

    /// Rechecks the persisted projection after its save. A different ModelContext
    /// can commit source changes while this context is awaiting detached math;
    /// if that happened, retain a durable retry marker instead of presenting a
    /// projection that no longer describes the saved source records.
    static func validateSavedProjectionWhileGateHeld(
        on date: Date,
        now: Date = Date(),
        in modelContext: ModelContext
    ) async throws {
        try await withProjectionErrorMapping {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: date)
            let snapshot = try projectionSnapshot(on: day, now: now, calendar: calendar, in: modelContext)
            let currentFingerprint = await Task.detached(priority: .utility) {
                DailyMetricsProjectionCalculator.fingerprint(for: snapshot.calculationInput)
            }.value
            guard let metric = try existingMetric(on: day, in: modelContext) else { return }
            guard !DailyMetricsProjectionFingerprint.sourceMatches(
                storedFingerprint: metric.sourceFingerprint,
                storedAlgorithmVersion: metric.projectionVersion,
                expectedFingerprint: currentFingerprint,
                expectedAlgorithmVersion: snapshot.calculationInput.fingerprintContext.algorithmVersion
            ) else { return }
            metric.requiresRecompute = true
            try modelContext.save()
        }
    }

    static func reprojectAndCommitWhileGateHeld(
        on date: Date,
        now: Date = Date(),
        in modelContext: ModelContext,
        willSaveProjection: (() throws -> Void)? = nil
    ) async throws {
        do {
            try await reprojectWhileGateHeld(on: date, now: now, in: modelContext)
            try willSaveProjection?()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        do {
            try await validateSavedProjectionWhileGateHeld(on: date, now: now, in: modelContext)
        } catch {
            try? markPendingForReprojectionWhileGateHeld(on: date, in: modelContext)
            try? modelContext.save()
            throw error
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
    ) async throws -> Bool {
        try await DailyMetricsProjectionWriteGate.withLock(
            for: modelContext,
            dayKeys: [DailyMetricsProjectionWriteGate.dayKey(for: date)]
        ) {
            try Task.checkCancellation()
            return try await withProjectionErrorMapping {
                let calendar = Calendar.current
                let day = calendar.startOfDay(for: date)
                for _ in 0..<3 {
                    guard let existingSnapshot = try existingMetric(on: day, in: modelContext).map({ metric in
                        ExistingMetricProjectionSnapshot(
                            sourceFingerprint: metric.sourceFingerprint,
                            projectionVersion: metric.projectionVersion,
                            requiresRecompute: metric.requiresRecompute
                        )
                    }), isHistoricalRecomputeCandidate(existingSnapshot) else {
                        return false
                    }

                    let asOf = HistoricalMetricsEligibilityPolicy.referenceDate(for: day, now: now, calendar: calendar)
                    let effectiveInputs = try resolveEffectiveInputs(on: day, asOf: asOf, in: modelContext)
                    guard HistoricalMetricsEligibilityPolicy.hasValidInputs(
                        profile: effectiveInputs.profile,
                        weight: effectiveInputs.weight,
                        asOf: asOf,
                        calendar: calendar
                    ) else { return false }

                    let projectionInputs = try DailyMetricsProjectionInputReader.read(
                    on: day,
                    calendar: calendar,
                    in: modelContext
                )
                    let healthSnapshot = try healthSnapshot(for: day, calendar: calendar, in: modelContext)
                    let fingerprintContext = try DailyMetricsProjectionFingerprint.context(
                    on: day,
                    calendar: calendar,
                    asOf: asOf,
                    inputs: projectionInputs,
                    profileRevision: effectiveInputs.profileRevision,
                    weightObservations: effectiveInputs.weightObservations,
                    in: modelContext
                )
                // Copy all SwiftData-backed input into Sendable values before leaving
                // this context. Only pure fingerprinting/accounting work runs detached.
                    let calculationInput = CaloricEngine.calculationInput(
                    date: day,
                    calendar: calendar,
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
                    let expectedFingerprint = await Task.detached(priority: .utility) {
                    DailyMetricsProjectionCalculator.fingerprint(for: calculationInput)
                }.value
                    if DailyMetricsProjectionFingerprint.sourceMatches(
                    storedFingerprint: existingSnapshot.sourceFingerprint,
                    storedAlgorithmVersion: existingSnapshot.projectionVersion,
                    expectedFingerprint: expectedFingerprint,
                    expectedAlgorithmVersion: fingerprintContext.algorithmVersion
                ), !existingSnapshot.requiresRecompute {
                        return false
                    }

                    let calculationResult = await Task.detached(priority: .utility) {
                    DailyMetricsProjectionCalculator.calculate(
                        calculationInput,
                        sourceFingerprint: expectedFingerprint
                    )
                }.value

                    let currentSnapshot = try projectionSnapshot(on: day, now: now, calendar: calendar, in: modelContext)
                    let currentFingerprint = await Task.detached(priority: .utility) {
                        DailyMetricsProjectionCalculator.fingerprint(for: currentSnapshot.calculationInput)
                    }.value
                    guard currentFingerprint == expectedFingerprint else { continue }
                    guard let currentExisting = try existingMetric(on: day, in: modelContext),
                          isHistoricalRecomputeCandidate(currentExisting) else { return false }

                    let projected = calculationResult.makeDailyMetrics()
                    copy(projected, to: currentExisting)
                    try modelContext.save()
                    try await validateSavedProjectionWhileGateHeld(on: day, now: now, in: modelContext)
                    return true
                }
                return false
            }
        }
    }

    private static func withProjectionErrorMapping<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch {
            throw DailyMetricsProjectionError.failed
        }
    }

    private static func withProjectionErrorMapping<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
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

    private static func isHistoricalRecomputeCandidate(_ snapshot: ExistingMetricProjectionSnapshot) -> Bool {
        snapshot.requiresRecompute
            || snapshot.projectionVersion != AlgorithmVersions.dailyMetricsProjection
            || snapshot.sourceFingerprint.isEmpty
    }

    private static func resolveEffectiveInputs(
        on day: Date,
        asOf referenceDate: Date,
        in modelContext: ModelContext
    ) throws -> EffectiveProjectionInputs {
        let primaryProfileKey = "primary"
        let profilePredicate = #Predicate<UserProfile> { $0.profileKey == primaryProfileKey }
        var profileDescriptor = FetchDescriptor<UserProfile>(
            predicate: profilePredicate,
            sortBy: [
                SortDescriptor(\.updatedAt, order: .reverse),
                SortDescriptor(\.createdAt),
                SortDescriptor(\.name),
            ]
        )
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

    private static func healthSnapshot(
        for day: Date,
        calendar: Calendar,
        in modelContext: ModelContext
    ) throws -> DailyHealthSnapshot? {
        guard let record = try healthSnapshotRecord(for: day, calendar: calendar, in: modelContext) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
    }

    private static func healthSnapshotRecord(
        for day: Date,
        calendar: Calendar,
        in modelContext: ModelContext
    ) throws -> DailyHealthSnapshotRecord? {
        let targetDayKey = dayKey(for: day, calendar: calendar)
        let predicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == targetDayKey }
        var descriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func dayKey(for day: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
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
