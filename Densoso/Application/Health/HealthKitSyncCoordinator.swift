import Foundation
import DensosoDomain

@MainActor
protocol HealthSyncRepository {
    func cursorSnapshot(for stream: String) throws -> HealthKitCursorSnapshot?
    func resetHealthKitCursors() async throws
    func resetHealthKitCursor(for stream: String) async throws
    func setHealthReadState(_ state: HealthReadState, metric: HealthMetricID, days: [Date]) async throws
    func maskCachedHealthDataBeforeAuthorizationBoundary(
        for metric: HealthMetricID,
        authorizationStart: Date,
        through: Date
    ) async throws
    func prepareHealthKitSnapshotRebuild(
        for metrics: Set<HealthMetricID>,
        from start: Date,
        through end: Date
    ) async throws
    func affectedHealthSampleDays(for page: HealthSamplePage, stream: String) throws -> [Date]
    func changedHealthSampleDays(for page: HealthSamplePage, stream: String) throws -> [Date]
    func pendingHealthSampleDays(stream: String) throws -> [Date]
    func applyImportedWorkouts(
        _ snapshots: [WorkoutSnapshot],
        deletedHealthKitUUIDs: [UUID],
        nextAnchorData: Data,
        lookbackStart: Date?,
        stream: String
    ) async throws
    func applyImportedHealthSamples(
        _ page: HealthSamplePage,
        stream: String,
        lastSuccessfulAt: Date,
        lookbackStart: Date?,
        replacements: [HealthSampleDaySnapshot]
    ) async throws
    func applyHealthAggregates(
        _ buckets: [HealthAggregateBucket],
        metric: HealthMetricID,
        stream: String,
        lookbackStart: Date,
        lastSuccessfulAt: Date
    ) async throws
}

struct HealthSyncResult: Sendable {
    let completedStreams: Set<HealthMetricID>
    let failedStreams: [HealthMetricID: HealthSyncFailure]

    var hasFailures: Bool { !failedStreams.isEmpty }
}

struct HealthKitSnapshotRebuildPreparation: Equatable, Sendable {
    let windowStart: Date
    let through: Date
}

private struct HealthSyncSupersededError: Error {}

struct HealthSyncFailure: Equatable, Sendable {
    let stream: HealthMetricID
    let requestID: UUID
    let descriptor: SharedErrorDescriptor

    var diagnosticSafeDetail: String {
        "HealthKitSyncError stream=\(stream.rawValue) underlying=\(descriptor.diagnosticSafeDetail) requestID=\(requestID.uuidString.lowercased())"
    }
}

@MainActor
final class HealthKitSyncCoordinator {
    static let aggregateStreams: Set<HealthMetricID> = [.activeEnergy, .restingEnergy, .stepCount, .exerciseMinutes]
    static let sampleStreams: Set<HealthMetricID> = [
        .workoutEffort, .sleepAnalysis, .heartRate, .restingHeartRate,
        .heartRateVariabilitySDNN, .respiratoryRate, .bodyMass, .height,
        .bodyFatPercentage, .wristTemperature,
    ]
    static let observedStreams = aggregateStreams.union(sampleStreams).union([.workout])

    private let healthStore: any HealthStoreClient
    private let observer: any HealthObserverClient
    private var observationRepository: (any HealthSyncRepository)?
    private var maskedAuthorizationBoundaryByMetric: [HealthMetricID: Date] = [:]
    private var scanGenerationByMetric: [HealthMetricID: UInt64] = [:]
    var onHealthCachePurgeWillBegin: (@MainActor () -> UInt64)?
    var onHealthCachePurgeDidSucceed: (@MainActor (UInt64) -> Void)?
    var onObserverSyncCompleted: (@MainActor (HealthMetricID, UInt64) async -> Void)?

    private struct WindowPlan {
        let targetStart: Date
        let queryStart: Date
        let authorizationStart: Date?
        let authorizationBoundaryUnavailable: Bool
    }

    init(
        healthStore: any HealthStoreClient = HealthKitHealthStoreClient(),
        observer: (any HealthObserverClient)? = nil
    ) {
        self.healthStore = healthStore
        self.observer = observer ?? (healthStore as? any HealthObserverClient) ?? HealthKitHealthStoreClient()
    }

    func authorizeAndStartBackgroundSync(using repository: any HealthSyncRepository) async throws -> Bool {
        guard await healthStore.isAvailable() else { throw HealthStoreClientError.unavailable }
        observationRepository = repository
        try await healthStore.requestAuthorization(.application)
        return try await startBackgroundObservers(using: repository)
    }

    /// Hides the current HealthKit window before foreground sync continues. The
    /// returned token lets the async sync reuse this completed purge.
    func prepareForegroundSnapshotRebuild(
        using repository: any HealthSyncRepository,
        now: Date = Date()
    ) async throws -> HealthKitSnapshotRebuildPreparation {
        guard let start = HealthDataWindowPolicy.initialBackfillStart(
            through: now,
            calendar: Calendar.current
        ) else {
            throw HealthStoreClientError.invalidAnchor
        }
        _ = try await prepareHealthKitSnapshotRebuild(
            for: Self.aggregateStreams.union(Self.sampleStreams).union([.workout]),
            from: start,
            through: now,
            using: repository
        )
        maskedAuthorizationBoundaryByMetric.removeAll()
        return HealthKitSnapshotRebuildPreparation(windowStart: start, through: now)
    }

    /// Invalidates older reads before touching cache state. The export gate opens
    /// only after the repository transaction has committed successfully.
    private func prepareHealthKitSnapshotRebuild(
        for metrics: Set<HealthMetricID>,
        from start: Date,
        through end: Date,
        using repository: any HealthSyncRepository
    ) async throws -> [HealthMetricID: UInt64] {
        let gateGeneration = onHealthCachePurgeWillBegin?()
        let scanGenerations = advanceScanGenerations(for: metrics)
        try await repository.prepareHealthKitSnapshotRebuild(
            for: metrics,
            from: start,
            through: end
        )
        if let gateGeneration {
            onHealthCachePurgeDidSucceed?(gateGeneration)
        }
        return scanGenerations
    }

    private func advanceScanGenerations(for metrics: Set<HealthMetricID>) -> [HealthMetricID: UInt64] {
        var generations: [HealthMetricID: UInt64] = [:]
        for metric in metrics {
            let next = (scanGenerationByMetric[metric] ?? 0) &+ 1
            scanGenerationByMetric[metric] = next
            generations[metric] = next
        }
        return generations
    }

    private func ensureCurrentScanGeneration(_ expected: UInt64, for metric: HealthMetricID) throws {
        guard scanGenerationByMetric[metric, default: 0] == expected else {
            throw HealthSyncSupersededError()
        }
    }

    func isCurrentScanGeneration(_ expected: UInt64, for metric: HealthMetricID) -> Bool {
        scanGenerationByMetric[metric, default: 0] == expected
    }

    private func ensureCurrentScanGenerations(_ expected: [HealthMetricID: UInt64]) throws {
        for (metric, generation) in expected {
            try ensureCurrentScanGeneration(generation, for: metric)
        }
    }

    @discardableResult
    func startBackgroundObservers(using repository: any HealthSyncRepository) async throws -> Bool {
        guard await healthStore.isAvailable() else { throw HealthStoreClientError.unavailable }
        observationRepository = repository
        try await observer.startObserving(Self.observedStreams) { [weak self] metric, systemCompletion in
            let completion = CompletionOnce(systemCompletion)
            Task { @MainActor in
                defer { completion.call() }
                guard let self else { return }
                guard let repository = self.observationRepository else { return }
                do {
                    let scanGeneration = try await self.sync(stream: metric, using: repository, now: Date())
                    try self.ensureCurrentScanGeneration(scanGeneration, for: metric)
                    await self.onObserverSyncCompleted?(metric, scanGeneration)
                }
                catch { /* The unchanged cursor makes the stream retryable on the next wakeup. */ }
            }
        }
        do {
            try await healthStore.enableBackgroundDelivery(for: Self.observedStreams)
            return true
        } catch {
            // Foreground observer queries remain useful when signing lacks the
            // background-delivery entitlement; report the limitation to Settings.
            return false
        }
    }

    func syncAvailableData(
        using repository: any HealthSyncRepository,
        now: Date = Date(),
        requestID: UUID = UUID(),
        forceRebaseline: Bool = false,
        preparedSnapshotRebuild: HealthKitSnapshotRebuildPreparation? = nil
    ) async throws -> HealthSyncResult {
        if forceRebaseline { maskedAuthorizationBoundaryByMetric.removeAll() }
        var windowPlans: [HealthMetricID: WindowPlan] = [:]
        var windowErrors: [HealthMetricID: Error] = [:]
        let windowedMetrics = Self.aggregateStreams.union(Self.sampleStreams).union([.workout])
        var scanGenerations = advanceScanGenerations(for: windowedMetrics)
        var snapshotRebuildMetrics = forceRebaseline ? windowedMetrics : Set<HealthMetricID>()
        var streamsToReset = Set<String>()
        if forceRebaseline {
            guard let start = HealthDataWindowPolicy.initialBackfillStart(
                through: now,
                calendar: Calendar.current
            ) else {
                throw HealthStoreClientError.invalidAnchor
            }
            do {
                if let preparedSnapshotRebuild {
                    guard preparedSnapshotRebuild.windowStart == start,
                          preparedSnapshotRebuild.through == now else {
                        throw HealthStoreClientError.invalidAnchor
                    }
                } else {
                    // Hide the prior cache before the first async HealthKit lookup so
                    // callers cannot use stale values while the rebaseline is running.
                    _ = try await prepareForegroundSnapshotRebuild(using: repository, now: now)
                }
                // A full sync owns the stream generations after the completed
                // purge and supersedes observer work started in the scheduling gap.
                scanGenerations = advanceScanGenerations(for: windowedMetrics)
            } catch {
                for metric in windowedMetrics {
                    windowErrors[metric] = error
                    try? await markHealthWindowUnknown(metric, from: start, through: now, using: repository)
                }
            }
        }
        guard await healthStore.isAvailable() else { throw HealthStoreClientError.unavailable }
        try ensureCurrentScanGenerations(scanGenerations)
        for metric in windowedMetrics.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                guard let scanGeneration = scanGenerations[metric] else {
                    throw HealthSyncSupersededError()
                }
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                let plan = try await makeWindowPlan(for: metric, now: now)
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                windowPlans[metric] = plan
                if !plan.authorizationBoundaryUnavailable {
                    if let generation = try await maskCachedHealthDataIfNeeded(
                        for: metric,
                        plan: plan,
                        through: now,
                        using: repository
                    ) {
                        scanGenerations[metric] = generation
                    }
                }
                if Self.aggregateStreams.contains(metric) {
                    // Aggregate reads are non-anchored snapshots. Clear the old
                    // window before each read so an empty/failed day stays unknown.
                    snapshotRebuildMetrics.insert(metric)
                }
                if Self.sampleStreams.contains(metric) || metric == .workout {
                    let stream = metric == .workout ? "workouts" : metric.rawValue
                    let cursor = try repository.cursorSnapshot(for: stream)
                    let needsRebaseline = cursor?.anchorData == nil || requiresRebaseline(
                        cursor: cursor,
                        policyStart: anchorPolicyStart(for: metric, targetStart: plan.targetStart),
                        authorizationStart: plan.authorizationStart
                    )
                    if forceRebaseline || plan.authorizationBoundaryUnavailable || needsRebaseline {
                        snapshotRebuildMetrics.insert(metric)
                        streamsToReset.insert(stream)
                    }
                }
            } catch {
                if error is HealthSyncSupersededError { throw error }
                guard let scanGeneration = scanGenerations[metric] else {
                    throw HealthSyncSupersededError()
                }
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                windowErrors[metric] = error
                if Self.sampleStreams.contains(metric) || metric == .workout {
                    streamsToReset.insert(metric == .workout ? "workouts" : metric.rawValue)
                }
                // An unexpected failure while planning the authorization window
                // cannot establish that cached values are still in scope. Hide
                // the current analysis window and reset anchored cursors so the
                // stream can retry from a fresh bounded read.
                if let analysisStart = HealthDataWindowPolicy.analysisStart(
                    through: now,
                    calendar: Calendar.current
                ) {
                    do {
                        try await markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                    } catch {
                        windowErrors[metric] = error
                    }
                }
            }
        }
        try ensureCurrentScanGenerations(scanGenerations)
        if !snapshotRebuildMetrics.isEmpty, !forceRebaseline {
            do {
                guard let start = windowPlans.values.map(\.targetStart).min() else {
                    throw HealthStoreClientError.invalidAnchor
                }
                let generations = try await prepareHealthKitSnapshotRebuild(
                    for: snapshotRebuildMetrics,
                    from: start,
                    through: now,
                    using: repository
                )
                scanGenerations.merge(generations, uniquingKeysWith: { _, new in new })
            } catch {
                if error is HealthSyncSupersededError { throw error }
                for metric in snapshotRebuildMetrics {
                    windowErrors[metric] = error
                    if let plan = windowPlans[metric],
                       let analysisStart = HealthDataWindowPolicy.analysisStart(
                        through: now,
                        calendar: Calendar.current
                       ) {
                        try? await markHealthWindowUnknown(
                            metric,
                            from: min(plan.targetStart, analysisStart),
                            through: now,
                            using: repository
                        )
                    }
                    if Self.sampleStreams.contains(metric) || metric == .workout {
                        streamsToReset.insert(metric == .workout ? "workouts" : metric.rawValue)
                    }
                }
            }
        }
        try ensureCurrentScanGenerations(scanGenerations)
        if forceRebaseline {
            try await repository.resetHealthKitCursors()
        } else {
            for stream in streamsToReset.sorted() {
                try await repository.resetHealthKitCursor(for: stream)
            }
        }
        var completedStreams = Set<HealthMetricID>()
        var failedStreams: [HealthMetricID: HealthSyncFailure] = [:]
        do {
            if let error = windowErrors[.workout] { throw error }
            guard let scanGeneration = scanGenerations[.workout] else {
                throw HealthSyncSupersededError()
            }
            try ensureCurrentScanGeneration(scanGeneration, for: .workout)
            guard let plan = windowPlans[.workout] else { throw HealthStoreClientError.invalidAnchor }
            try await syncWorkouts(
                repository: repository,
                now: now,
                plan: plan,
                scanGeneration: scanGeneration
            )
            completedStreams.insert(.workout)
        } catch let error as HealthSyncSupersededError {
            throw error
        } catch {
            failedStreams[.workout] = makeFailure(error, stream: .workout, requestID: requestID)
        }
        for metric in Self.aggregateStreams.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let error = windowErrors[metric] {
                failedStreams[metric] = makeFailure(error, stream: metric, requestID: requestID)
                continue
            }
            do {
                guard let scanGeneration = scanGenerations[metric] else {
                    throw HealthSyncSupersededError()
                }
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                guard let plan = windowPlans[metric] else { throw HealthStoreClientError.invalidAnchor }
                try await syncAggregate(
                    metric,
                    repository: repository,
                    now: now,
                    plan: plan,
                    scanGeneration: scanGeneration
                )
                completedStreams.insert(metric)
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                failedStreams[metric] = makeFailure(error, stream: metric, requestID: requestID)
            }
        }
        for metric in Self.sampleStreams.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let error = windowErrors[metric] {
                failedStreams[metric] = makeFailure(error, stream: metric, requestID: requestID)
                continue
            }
            do {
                guard let scanGeneration = scanGenerations[metric] else {
                    throw HealthSyncSupersededError()
                }
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                guard let plan = windowPlans[metric] else { throw HealthStoreClientError.invalidAnchor }
                try await syncSamples(
                    metric,
                    repository: repository,
                    now: now,
                    plan: plan,
                    scanGeneration: scanGeneration
                )
                completedStreams.insert(metric)
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                failedStreams[metric] = makeFailure(error, stream: metric, requestID: requestID)
            }
        }
        try ensureCurrentScanGenerations(scanGenerations)
        return HealthSyncResult(completedStreams: completedStreams, failedStreams: failedStreams)
    }

    private func maskCachedHealthDataIfNeeded(
        for metric: HealthMetricID,
        plan: WindowPlan,
        through date: Date,
        using repository: any HealthSyncRepository
    ) async throws -> UInt64? {
        guard let authorizationStart = plan.authorizationStart else {
            maskedAuthorizationBoundaryByMetric.removeValue(forKey: metric)
            return nil
        }
        guard maskedAuthorizationBoundaryByMetric[metric] != authorizationStart else { return nil }
        let gateGeneration = onHealthCachePurgeWillBegin?()
        let scanGeneration = advanceScanGenerations(for: [metric])[metric]
        try await repository.maskCachedHealthDataBeforeAuthorizationBoundary(
            for: metric,
            authorizationStart: authorizationStart,
            through: date
        )
        maskedAuthorizationBoundaryByMetric[metric] = authorizationStart
        if let gateGeneration {
            onHealthCachePurgeDidSucceed?(gateGeneration)
        }
        return scanGeneration
    }

    private func markHealthWindowUnknown(
        _ metric: HealthMetricID,
        from start: Date,
        through end: Date,
        using repository: any HealthSyncRepository
    ) async throws {
        try await repository.setHealthReadState(
            .dataUnavailableOrReadScopeUnknown,
            metric: metric,
            days: HealthDataWindowPolicy.days(from: start, through: end, calendar: Calendar.current)
        )
    }

    private func makeFailure(_ error: Error, stream: HealthMetricID, requestID: UUID) -> HealthSyncFailure {
        HealthSyncFailure(
            stream: stream,
            requestID: requestID,
            descriptor: SharedErrorDescriptor.mapped(
                from: error,
                fallback: .healthKitUnavailableFallback
            )
        )
    }

    private func sync(
        stream metric: HealthMetricID,
        using repository: any HealthSyncRepository,
        now: Date
    ) async throws -> UInt64 {
        var scanGeneration = advanceScanGenerations(for: [metric])[metric]
            ?? scanGenerationByMetric[metric, default: 0]
        let available = await healthStore.isAvailable()
        try ensureCurrentScanGeneration(scanGeneration, for: metric)
        guard available else { return scanGeneration }
        if metric == .workout {
            let plan: WindowPlan
            do {
                plan = try await makeWindowPlan(for: metric, now: now)
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                if let analysisStart = HealthDataWindowPolicy.analysisStart(through: now, calendar: Calendar.current) {
                    try? await markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                }
                try await repository.resetHealthKitCursor(for: "workouts")
                throw error
            }
            if !plan.authorizationBoundaryUnavailable {
                if let generation = try await maskCachedHealthDataIfNeeded(
                    for: metric,
                    plan: plan,
                    through: now,
                    using: repository
                ) {
                    scanGeneration = generation
                }
            }
            let cursor = try repository.cursorSnapshot(for: "workouts")
            let needsRebaseline = cursor?.anchorData == nil || requiresRebaseline(
                cursor: cursor,
                policyStart: plan.targetStart,
                authorizationStart: plan.authorizationStart
            )
            if plan.authorizationBoundaryUnavailable || needsRebaseline {
                let generations = try await prepareHealthKitSnapshotRebuild(
                    for: [metric],
                    from: plan.targetStart,
                    through: now,
                    using: repository
                )
                scanGeneration = generations[metric] ?? scanGenerationByMetric[metric, default: 0]
            }
            try await syncWorkouts(
                repository: repository,
                now: now,
                plan: plan,
                scanGeneration: scanGeneration
            )
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            return scanGeneration
        } else if Self.aggregateStreams.contains(metric) {
            let plan: WindowPlan
            do {
                plan = try await makeWindowPlan(for: metric, now: now)
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                if let analysisStart = HealthDataWindowPolicy.analysisStart(through: now, calendar: Calendar.current) {
                    try? await markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                }
                throw error
            }
            if !plan.authorizationBoundaryUnavailable {
                if let generation = try await maskCachedHealthDataIfNeeded(
                    for: metric,
                    plan: plan,
                    through: now,
                    using: repository
                ) {
                    scanGeneration = generation
                }
            }
            let generations = try await prepareHealthKitSnapshotRebuild(
                for: [metric],
                from: plan.targetStart,
                through: now,
                using: repository
            )
            scanGeneration = generations[metric] ?? scanGenerationByMetric[metric, default: 0]
            try await syncAggregate(
                metric,
                repository: repository,
                now: now,
                plan: plan,
                scanGeneration: scanGeneration
            )
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            return scanGeneration
        } else if Self.sampleStreams.contains(metric) {
            let plan: WindowPlan
            do {
                plan = try await makeWindowPlan(for: metric, now: now)
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                if let analysisStart = HealthDataWindowPolicy.analysisStart(through: now, calendar: Calendar.current) {
                    try? await markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                }
                try await repository.resetHealthKitCursor(for: metric.rawValue)
                throw error
            }
            if !plan.authorizationBoundaryUnavailable {
                if let generation = try await maskCachedHealthDataIfNeeded(
                    for: metric,
                    plan: plan,
                    through: now,
                    using: repository
                ) {
                    scanGeneration = generation
                }
            }
            let cursor = try repository.cursorSnapshot(for: metric.rawValue)
            let needsRebaseline = cursor?.anchorData == nil || requiresRebaseline(
                cursor: cursor,
                policyStart: anchorPolicyStart(for: metric, targetStart: plan.targetStart),
                authorizationStart: plan.authorizationStart
            )
            if plan.authorizationBoundaryUnavailable || needsRebaseline {
                let generations = try await prepareHealthKitSnapshotRebuild(
                    for: [metric],
                    from: plan.targetStart,
                    through: now,
                    using: repository
                )
                scanGeneration = generations[metric] ?? scanGenerationByMetric[metric, default: 0]
            }
            try await syncSamples(
                metric,
                repository: repository,
                now: now,
                plan: plan,
                scanGeneration: scanGeneration
            )
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            return scanGeneration
        }
        return scanGeneration
    }

    private func makeWindowPlan(
        for metric: HealthMetricID,
        now: Date
    ) async throws -> WindowPlan {
        let calendar = Calendar.current
        guard let targetStart = HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar) else {
            throw HealthStoreClientError.invalidAnchor
        }
        let authorizationStart: Date?
        let authorizationBoundaryUnavailable: Bool
        if let provider = healthStore as? any HealthAuthorizationBoundaryProviding {
            do {
                authorizationStart = try await provider.earliestAuthorizedSampleDate(for: metric)
                authorizationBoundaryUnavailable = false
            } catch let error as HealthStoreClientError where error == .authorizationBoundaryUnavailable {
                // Keep the difference between “no limited window” and “the API is
                // unavailable on this OS.” Rebuild the bounded cache from a current
                // HealthKit snapshot rather than treating unavailable as no boundary.
                authorizationStart = nil
                authorizationBoundaryUnavailable = true
            }
        } else {
            authorizationStart = nil
            authorizationBoundaryUnavailable = false
        }
        let policyStart = anchorPolicyStart(for: metric, targetStart: targetStart)
        let queryStart = HealthDataWindowPolicy.effectiveStart(
            policyStart: policyStart,
            authorizationStart: authorizationStart
        )
        return WindowPlan(
            targetStart: targetStart,
            queryStart: queryStart,
            authorizationStart: authorizationStart,
            authorizationBoundaryUnavailable: authorizationBoundaryUnavailable
        )
    }

    private func anchorPolicyStart(for metric: HealthMetricID, targetStart: Date) -> Date {
        guard metric == .sleepAnalysis else { return targetStart }
        let calendar = Calendar.current
        let previousDay = calendar.date(byAdding: .day, value: -1, to: targetStart) ?? targetStart
        return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay) ?? targetStart
    }

    private func requiresRebaseline(
        cursor: HealthKitCursorSnapshot?,
        policyStart: Date,
        authorizationStart: Date?
    ) -> Bool {
        if cursor?.anchorData != nil, cursor?.lookbackStart == nil { return true }
        return HealthDataWindowPolicy.requiresRebaseline(
            cursorStart: cursor?.lookbackStart,
            policyStart: policyStart,
            authorizationStart: authorizationStart
        )
    }

    private func syncWorkouts(
        repository: any HealthSyncRepository,
        now: Date,
        plan: WindowPlan,
        scanGeneration: UInt64
    ) async throws {
        let cursor = try repository.cursorSnapshot(for: "workouts")
        let start = min(cursor?.lookbackStart ?? plan.queryStart, plan.queryStart)
        var anchor = cursor?.anchorData
        while true {
            let page = try await healthStore.workoutChanges(from: start, after: anchor)
            try ensureCurrentScanGeneration(scanGeneration, for: .workout)
            guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
            let allowedStart = HealthDataWindowPolicy.effectiveStart(
                policyStart: start,
                authorizationStart: plan.authorizationStart
            )
            let allowedWorkouts = page.added.filter { $0.startedAt >= allowedStart }
            try await repository.applyImportedWorkouts(
                allowedWorkouts,
                deletedHealthKitUUIDs: page.deletedObjectIDs,
                nextAnchorData: nextAnchor,
                lookbackStart: start,
                stream: "workouts"
            )
            try await repository.setHealthReadState(
                .available,
                metric: .workout,
                days: allowedWorkouts.compactMap { workout in
                    let day = Calendar.current.startOfDay(for: workout.startedAt)
                    guard plan.authorizationStart.map({ day >= $0 }) ?? true else { return nil }
                    return day
                }
            )
            if !page.hasMore { return }
            guard nextAnchor != anchor else { throw HealthStoreClientError.invalidAnchor }
            anchor = nextAnchor
        }
    }

    private func syncAggregate(
        _ metric: HealthMetricID,
        repository: any HealthSyncRepository,
        now: Date,
        plan: WindowPlan,
        scanGeneration: UInt64
    ) async throws {
        let stream = metric.rawValue
        let calendar = Calendar.current
        let buckets = try await healthStore.aggregate(HealthAggregateRequest(
            metric: metric,
            startDate: plan.queryStart,
            endDate: now,
            timezoneIdentifier: calendar.timeZone.identifier
        ))
        try ensureCurrentScanGeneration(scanGeneration, for: metric)
        let coveredBuckets = bucketsWithAuthorizationUnknowns(
            buckets,
            plan: plan,
            through: now,
            calendar: calendar
        )
        try await repository.applyHealthAggregates(
            coveredBuckets,
            metric: metric,
            stream: stream,
            lookbackStart: plan.queryStart,
            lastSuccessfulAt: now
        )
    }

    private func syncSamples(
        _ metric: HealthMetricID,
        repository: any HealthSyncRepository,
        now: Date,
        plan: WindowPlan,
        scanGeneration: UInt64
    ) async throws {
        let stream = metric.rawValue
        let cursor = try repository.cursorSnapshot(for: stream)
        // Reuse the exact predicate associated with an existing HealthKit anchor.
        let start = min(cursor?.lookbackStart ?? plan.queryStart, plan.queryStart)
        var anchor = cursor?.anchorData
        var isFirstPage = true
        repeat {
            let page = try await healthStore.samples(HealthSampleRequest(
                metric: metric,
                startDate: start,
                // Keep the anchored query predicate stable. The cursor's lower bound
                // is persisted per stream; a fixed open upper bound avoids changing
                // the predicate while reusing HealthKit's opaque anchor.
                endDate: .distantFuture,
                anchorData: anchor,
                limit: 500
            ))
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
            let allowedStart = HealthDataWindowPolicy.effectiveStart(
                policyStart: start,
                authorizationStart: plan.authorizationStart
            )
            let allowedPage = HealthSamplePage(
                samples: page.samples.filter { $0.startDate >= allowedStart },
                deletedSampleIDs: page.deletedSampleIDs,
                nextAnchorData: page.nextAnchorData,
                hasMore: page.hasMore,
                readState: page.readState
            )
            // The anchored query keeps its original lower bound so HealthKit can
            // return late changes to previously indexed days outside the current
            // analysis window. Requery those affected days too; the analysis
            // window remains bounded separately by HealthDataWindowPolicy.
            let affectedDays = try repository.affectedHealthSampleDays(for: allowedPage, stream: stream)
            let replacements = try await requerySampleDays(
                metric: metric,
                days: affectedDays,
                plan: plan,
                through: now,
                scanGeneration: scanGeneration
            )
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            let authorizationUnknowns = isFirstPage
                ? sampleDaysBeforeAuthorization(metric: metric, plan: plan, through: now)
                : []
            try await repository.applyImportedHealthSamples(
                allowedPage,
                stream: stream,
                lastSuccessfulAt: now,
                lookbackStart: start,
                replacements: mergeDaySnapshots(authorizationUnknowns, replacements)
            )
            isFirstPage = false
            if !page.hasMore { return }
            guard nextAnchor != anchor else { throw HealthStoreClientError.invalidAnchor }
            anchor = nextAnchor
        } while true
    }

    private func bucketsWithAuthorizationUnknowns(
        _ buckets: [HealthAggregateBucket],
        plan: WindowPlan,
        through date: Date,
        calendar: Calendar
    ) -> [HealthAggregateBucket] {
        guard let authorizationStart = plan.authorizationStart else { return buckets }
        let endDay = calendar.startOfDay(for: date)
        var byDay = Dictionary(
            buckets.map { (calendar.startOfDay(for: $0.startDate), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        for day in HealthDataWindowPolicy.days(from: plan.targetStart, through: endDay, calendar: calendar)
            where day < authorizationStart {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            byDay[day] = HealthAggregateBucket(
                startDate: day,
                endDate: nextDay,
                value: nil,
                readState: .dataUnavailableOrReadScopeUnknown
            )
        }
        return byDay.values.sorted { $0.startDate < $1.startDate }
    }

    private func sampleDaysBeforeAuthorization(
        metric: HealthMetricID,
        plan: WindowPlan,
        through date: Date
    ) -> [HealthSampleDaySnapshot] {
        guard let authorizationStart = plan.authorizationStart else { return [] }
        let calendar = Calendar.current
        return HealthDataWindowPolicy.days(
            from: plan.targetStart,
            through: calendar.startOfDay(for: date),
            calendar: calendar
        ).compactMap { day in
            let queryStart: Date
            if metric == .sleepAnalysis,
               let previousDay = calendar.date(byAdding: .day, value: -1, to: day),
               let sleepStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay) {
                queryStart = sleepStart
            } else {
                queryStart = day
            }
            guard queryStart < authorizationStart else { return nil }
            return HealthSampleDaySnapshot(
                dayStart: day,
                samples: [],
                readState: .dataUnavailableOrReadScopeUnknown
            )
        }
    }

    private func mergeDaySnapshots(
        _ authorizationUnknowns: [HealthSampleDaySnapshot],
        _ replacements: [HealthSampleDaySnapshot]
    ) -> [HealthSampleDaySnapshot] {
        var byDay = Dictionary(
            authorizationUnknowns.map { ($0.dayStart, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        for replacement in replacements { byDay[replacement.dayStart] = replacement }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private func requerySampleDays(
        metric: HealthMetricID,
        days: [Date],
        plan: WindowPlan,
        through date: Date,
        scanGeneration: UInt64
    ) async throws -> [HealthSampleDaySnapshot] {
        let calendar = Calendar.current
        var replacements: [HealthSampleDaySnapshot] = []
        let throughDay = calendar.startOfDay(for: date)
        for date in days.sorted() {
            let day = calendar.startOfDay(for: date)
            guard day <= throughDay else { continue }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let queryStart: Date
            let queryEnd: Date
            if metric == .sleepAnalysis,
               let previousDay = calendar.date(byAdding: .day, value: -1, to: day),
               let windowStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay),
               let windowEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) {
                queryStart = windowStart
                queryEnd = windowEnd
            } else {
                queryStart = day
                queryEnd = nextDay
            }
            if let authorizationStart = plan.authorizationStart, queryStart < authorizationStart {
                replacements.append(HealthSampleDaySnapshot(
                    dayStart: day,
                    samples: [],
                    readState: .dataUnavailableOrReadScopeUnknown
                ))
                continue
            }
            var samplesByID: [UUID: HealthSampleSnapshot] = [:]
            var anchor: Data?
            var readState: HealthReadState = .dataUnavailableOrReadScopeUnknown
            while true {
                let page = try await healthStore.samples(HealthSampleRequest(
                    metric: metric,
                    startDate: queryStart,
                    endDate: queryEnd,
                    anchorData: anchor,
                    limit: 500
                ))
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
                for sample in page.samples {
                    if let existing = samplesByID[sample.id] {
                        if HealthSampleSnapshot.preferredForDeduplication(sample, over: existing) {
                            samplesByID[sample.id] = sample
                        }
                    } else {
                        samplesByID[sample.id] = sample
                    }
                }
                if !page.samples.isEmpty { readState = .available }
                else if samplesByID.isEmpty { readState = page.readState }
                if !page.hasMore { break }
                guard nextAnchor != anchor else { throw HealthStoreClientError.invalidAnchor }
                anchor = nextAnchor
            }
            let samples = samplesByID.values.sorted(by: HealthSampleSnapshot.stableDeduplicationOrder)
            replacements.append(HealthSampleDaySnapshot(
                dayStart: day,
                samples: samples,
                readState: readState
            ))
        }
        return replacements
    }

}

private final class CompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var hasCompleted = false
    private let completion: @Sendable () -> Void

    init(_ completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    func call() {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        lock.unlock()
        completion()
    }
}
