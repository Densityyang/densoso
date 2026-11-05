import Foundation
import DensosoDomain

@MainActor
protocol HealthSyncRepository {
    func cursorSnapshot(for stream: String) throws -> HealthKitCursorSnapshot?
    func hasAvailableHealthReadState(
        for metric: HealthMetricID,
        from start: Date,
        through end: Date
    ) throws -> Bool
    func hasImportedHealthKitWorkout(from start: Date, through end: Date) throws -> Bool
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
        stream: String,
        readStateUpdates: [Date: HealthReadState]
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
        through: Date,
        lastSuccessfulAt: Date
    ) async throws
}

struct HealthSyncResult: Sendable {
    let completedStreams: Set<HealthMetricID>
    let failedStreams: [HealthMetricID: HealthSyncFailure]
    let readRecordCount: Int

    init(
        completedStreams: Set<HealthMetricID>,
        failedStreams: [HealthMetricID: HealthSyncFailure],
        readRecordCount: Int = 0
    ) {
        self.completedStreams = completedStreams
        self.failedStreams = failedStreams
        self.readRecordCount = max(readRecordCount, 0)
    }

    var hasFailures: Bool { !failedStreams.isEmpty }
}

@MainActor
private final class HealthSyncReadRecordCounter {
    private(set) var count = 0

    func add(_ amount: Int) {
        count += max(amount, 0)
    }
}

struct HealthKitSnapshotRebuildPreparation: Equatable, Sendable {
    let windowStart: Date
    let through: Date
    let timeZoneIdentifier: String
}

struct HealthSyncSupersededError: Error, CustomStringConvertible {
    private let diagnostic: String?

    init(metric: HealthMetricID? = nil, expected: UInt64? = nil, actual: UInt64? = nil) {
        guard let metric, let expected, let actual else {
            diagnostic = nil
            return
        }
        diagnostic = "metric=\(metric.rawValue) expectedGeneration=\(expected) actualGeneration=\(actual)"
    }

    var description: String {
        "HealthSyncSupersededError(\(diagnostic ?? "unknown generation"))"
    }
}

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
    private let persistenceOperationBarrier: PersistenceOperationBarrier
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

    private struct WorkoutSyncOutcome {
        let generation: UInt64
        let hasChanges: Bool
    }

    init(
        healthStore: any HealthStoreClient = HealthKitHealthStoreClient(),
        observer: (any HealthObserverClient)? = nil,
        persistenceOperationBarrier: PersistenceOperationBarrier = .shared
    ) {
        self.healthStore = healthStore
        self.observer = observer ?? (healthStore as? any HealthObserverClient) ?? HealthKitHealthStoreClient()
        self.persistenceOperationBarrier = persistenceOperationBarrier
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
        now: Date = Date(),
        onScanGenerationsAdvanced: (([HealthMetricID: UInt64]) -> Void)? = nil
    ) async throws -> HealthKitSnapshotRebuildPreparation {
        let calendar = Calendar.autoupdatingCurrent
        let timeZoneIdentifier = calendar.timeZone.identifier
        guard let start = HealthDataWindowPolicy.initialBackfillStart(
            through: now,
            calendar: calendar
        ) else {
            throw HealthStoreClientError.invalidAnchor
        }
        _ = try await prepareHealthKitSnapshotRebuild(
            for: Self.aggregateStreams.union(Self.sampleStreams).union([.workout]),
            from: start,
            through: now,
            using: repository,
            onScanGenerationsAdvanced: onScanGenerationsAdvanced
        )
        maskedAuthorizationBoundaryByMetric.removeAll()
        return HealthKitSnapshotRebuildPreparation(
            windowStart: start,
            through: now,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    /// Invalidates older reads before touching cache state. The export gate opens
    /// only after the repository transaction has committed successfully.
    private func prepareHealthKitSnapshotRebuild(
        for metrics: Set<HealthMetricID>,
        from start: Date,
        through end: Date,
        using repository: any HealthSyncRepository,
        openExportGateOnSuccess: Bool = true,
        onScanGenerationsAdvanced: (([HealthMetricID: UInt64]) -> Void)? = nil
    ) async throws -> [HealthMetricID: UInt64] {
        let gateGeneration = onHealthCachePurgeWillBegin?()
        let scanGenerations = advanceScanGenerations(for: metrics)
        onScanGenerationsAdvanced?(scanGenerations)
        try await PerformanceSignposts.measureAsync("Health.SnapshotRebuild") {
            try await repository.prepareHealthKitSnapshotRebuild(
                for: metrics,
                from: start,
                through: end
            )
        }
        if openExportGateOnSuccess, let gateGeneration {
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
        let actual = scanGenerationByMetric[metric, default: 0]
        guard actual == expected else {
            throw HealthSyncSupersededError(metric: metric, expected: expected, actual: actual)
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
                await PerformanceSignposts.measureAsync("Health.ObserverSync") {
                    do {
                        let scanGeneration = try await self.syncObservedStream(metric, using: repository, now: Date())
                        try self.ensureCurrentScanGeneration(scanGeneration, for: metric)
                        await self.onObserverSyncCompleted?(metric, scanGeneration)
                    }
                    catch { /* The unchanged cursor makes the stream retryable on the next wakeup. */ }
                }
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
        preparedSnapshotRebuild: HealthKitSnapshotRebuildPreparation? = nil,
        aggregateIncrementalLookbackDays: Int? = nil
    ) async throws -> HealthSyncResult {
        let readRecordCounter = HealthSyncReadRecordCounter()
        let isFullSync = forceRebaseline || preparedSnapshotRebuild != nil
        defer {
            if isFullSync {
                PerformanceSignposts.event(
                    "Health.FullSyncReadRecordCount",
                    count: readRecordCounter.count
                )
            }
        }
        let operationLease = try await persistenceOperationBarrier.acquireHealthImportOperation()
        defer { persistenceOperationBarrier.release(operationLease) }
        return try await persistenceOperationBarrier.withLease(operationLease) {
            try await syncAvailableDataWhileLeased(
                using: repository,
                now: now,
                requestID: requestID,
                forceRebaseline: forceRebaseline,
                preparedSnapshotRebuild: preparedSnapshotRebuild,
                aggregateIncrementalLookbackDays: aggregateIncrementalLookbackDays,
                readRecordCounter: readRecordCounter
            )
        }
    }

    private func syncAvailableDataWhileLeased(
        using repository: any HealthSyncRepository,
        now: Date,
        requestID: UUID,
        forceRebaseline: Bool,
        preparedSnapshotRebuild: HealthKitSnapshotRebuildPreparation?,
        aggregateIncrementalLookbackDays: Int?,
        readRecordCounter: HealthSyncReadRecordCounter
    ) async throws -> HealthSyncResult {
        if forceRebaseline { maskedAuthorizationBoundaryByMetric.removeAll() }
        var windowPlans: [HealthMetricID: WindowPlan] = [:]
        var windowErrors: [HealthMetricID: Error] = [:]
        var exportGateMustRemainClosed = false
        let windowedMetrics = Self.aggregateStreams.union(Self.sampleStreams).union([.workout])
        var scanGenerations = advanceScanGenerations(for: windowedMetrics)
        var snapshotRebuildMetrics = forceRebaseline ? windowedMetrics : Set<HealthMetricID>()
        var streamsToReset = Set<String>()
        if forceRebaseline {
            let start: Date
            if let preparedSnapshotRebuild {
                // The prepared range is the range the repository actually purged.
                // Recomputing it from an autoupdating calendar here can produce a
                // different day boundary if the device time zone changed between
                // preparation and sync, falsely turning a successful purge into a
                // failed rebaseline.
                guard preparedSnapshotRebuild.through == now else {
                    throw HealthStoreClientError.invalidAnchor
                }
                guard preparedSnapshotRebuild.timeZoneIdentifier == Calendar.autoupdatingCurrent.timeZone.identifier else {
                    // Do not mix a cache purge made in one local time zone with
                    // projections made in another. The foreground coordinator
                    // can safely retry preparation using the new zone.
                    throw HealthStoreClientError.invalidAnchor
                }
                start = preparedSnapshotRebuild.windowStart
            } else {
                guard let currentStart = HealthDataWindowPolicy.initialBackfillStart(
                    through: now,
                    calendar: Calendar.autoupdatingCurrent
                ) else {
                    throw HealthStoreClientError.invalidAnchor
                }
                start = currentStart
            }
            do {
                if preparedSnapshotRebuild == nil {
                    // Hide the prior cache before the first async HealthKit lookup so
                    // callers cannot use stale values while the rebaseline is running.
                    _ = try await prepareForegroundSnapshotRebuild(
                        using: repository,
                        now: now,
                        onScanGenerationsAdvanced: { generations in
                            scanGenerations.merge(generations, uniquingKeysWith: { _, new in new })
                        }
                    )
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
                var plan = try await makeWindowPlan(for: metric, now: now)
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                if Self.aggregateStreams.contains(metric),
                   !forceRebaseline,
                   !plan.authorizationBoundaryUnavailable {
                    plan = incrementalAggregatePlan(
                        plan,
                        cursor: try repository.cursorSnapshot(for: metric.rawValue),
                        lookbackDays: aggregateIncrementalLookbackDays,
                        now: now
                    )
                }
                windowPlans[metric] = plan
                if !plan.authorizationBoundaryUnavailable {
                    if let generation = try await maskCachedHealthDataIfNeeded(
                        for: metric,
                        plan: plan,
                        through: now,
                        using: repository,
                        onScanGenerationAdvanced: { scanGenerations[metric] = $0 }
                    ) {
                        scanGenerations[metric] = generation
                    }
                }
                if Self.aggregateStreams.contains(metric) {
                    // Only rebuild aggregate snapshots when the system cannot
                    // establish their authorization boundary. Routine aggregate
                    // refreshes replace their bounded query window transactionally.
                    if plan.authorizationBoundaryUnavailable {
                        snapshotRebuildMetrics.insert(metric)
                    }
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
                var planningFailure = error
                if Self.sampleStreams.contains(metric) || metric == .workout {
                    let stream = metric == .workout ? "workouts" : metric.rawValue
                    streamsToReset.insert(stream)
                    let analysisStart = HealthDataWindowPolicy.analysisStart(
                        through: now,
                        calendar: Calendar.autoupdatingCurrent
                    ) ?? now
                    do {
                        let rebuiltGeneration = try await prepareTargetedStreamRebuild(
                            metric,
                            from: analysisStart,
                            through: now,
                            using: repository,
                            onScanGenerationAdvanced: { scanGenerations[metric] = $0 }
                        )
                        scanGenerations[metric] = rebuiltGeneration
                    } catch {
                        await leaveStreamUnknownAndRetryable(
                            metric,
                            stream: stream,
                            from: analysisStart,
                            through: now,
                            using: repository
                        )
                        planningFailure = error
                    }
                } else if let analysisStart = HealthDataWindowPolicy.analysisStart(
                    through: now,
                    calendar: Calendar.autoupdatingCurrent
                ) {
                    // Aggregate cache is gated at export and read-state is the
                    // fail-closed boundary when planning cannot establish scope.
                    do {
                        try await markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                    } catch {
                        planningFailure = error
                    }
                }
                windowErrors[metric] = planningFailure
            }
        }
        try ensureCurrentScanGenerations(scanGenerations)
        if !snapshotRebuildMetrics.isEmpty, !forceRebaseline {
            do {
                guard let start = snapshotRebuildMetrics
                    .compactMap({ windowPlans[$0]?.targetStart })
                    .min() else {
                    throw HealthStoreClientError.invalidAnchor
                }
                let generations = try await prepareHealthKitSnapshotRebuild(
                    for: snapshotRebuildMetrics,
                    from: start,
                    through: now,
                    using: repository,
                    onScanGenerationsAdvanced: { generations in
                        scanGenerations.merge(generations, uniquingKeysWith: { _, new in new })
                    }
                )
                scanGenerations.merge(generations, uniquingKeysWith: { _, new in new })
            } catch {
                if error is HealthSyncSupersededError { throw error }
                for metric in snapshotRebuildMetrics {
                    windowErrors[metric] = error
                    if let plan = windowPlans[metric],
                       let analysisStart = HealthDataWindowPolicy.analysisStart(
                        through: now,
                        calendar: Calendar.autoupdatingCurrent
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
            let workoutOutcome = try await syncWorkouts(
                repository: repository,
                now: now,
                plan: plan,
                scanGeneration: scanGeneration,
                readRecordCounter: readRecordCounter,
                onScanGenerationAdvanced: { scanGenerations[.workout] = $0 }
            )
            scanGenerations[.workout] = workoutOutcome.generation
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
                    scanGeneration: scanGeneration,
                    readRecordCounter: readRecordCounter
                )
                completedStreams.insert(metric)
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                if !snapshotRebuildMetrics.contains(metric), let plan = windowPlans[metric] {
                    try? await markHealthWindowUnknown(metric, from: plan.targetStart, through: now, using: repository)
                }
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
                let completedGeneration = try await syncSamples(
                    metric,
                    repository: repository,
                    now: now,
                    plan: plan,
                    scanGeneration: scanGeneration,
                    readRecordCounter: readRecordCounter,
                    onScanGenerationAdvanced: { scanGenerations[metric] = $0 }
                )
                scanGenerations[metric] = completedGeneration
                completedStreams.insert(metric)
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                failedStreams[metric] = makeFailure(error, stream: metric, requestID: requestID)
            }
        }
        try ensureCurrentScanGenerations(scanGenerations)
        return HealthSyncResult(
            completedStreams: completedStreams,
            failedStreams: failedStreams,
            readRecordCount: readRecordCounter.count
        )
    }

    private func maskCachedHealthDataIfNeeded(
        for metric: HealthMetricID,
        plan: WindowPlan,
        through date: Date,
        using repository: any HealthSyncRepository,
        onScanGenerationAdvanced: ((UInt64) -> Void)? = nil
    ) async throws -> UInt64? {
        guard let authorizationStart = plan.authorizationStart else {
            maskedAuthorizationBoundaryByMetric.removeValue(forKey: metric)
            return nil
        }
        guard maskedAuthorizationBoundaryByMetric[metric] != authorizationStart else { return nil }
        let gateGeneration = onHealthCachePurgeWillBegin?()
        let scanGeneration = advanceScanGenerations(for: [metric])[metric]
        if let scanGeneration { onScanGenerationAdvanced?(scanGeneration) }
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
            days: HealthDataWindowPolicy.days(from: start, through: end, calendar: Calendar.autoupdatingCurrent)
        )
    }

    private func syncObservedStream(
        _ metric: HealthMetricID,
        using repository: any HealthSyncRepository,
        now: Date
    ) async throws -> UInt64 {
        let operationLease = try await persistenceOperationBarrier.acquireHealthImportOperation()
        defer { persistenceOperationBarrier.release(operationLease) }
        return try await persistenceOperationBarrier.withLease(operationLease) {
            try await sync(stream: metric, using: repository, now: now)
        }
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
                let planningFailure = error
                let analysisStart = HealthDataWindowPolicy.analysisStart(
                    through: now,
                    calendar: Calendar.autoupdatingCurrent
                ) ?? now
                do {
                    let rebuiltGeneration = try await prepareTargetedStreamRebuild(
                        metric,
                        from: analysisStart,
                        through: now,
                        using: repository,
                        onScanGenerationAdvanced: { scanGeneration = $0 }
                    )
                    scanGeneration = rebuiltGeneration
                } catch {
                    await leaveStreamUnknownAndRetryable(
                        metric,
                        stream: "workouts",
                        from: analysisStart,
                        through: now,
                        using: repository
                    )
                    throw error
                }
                throw planningFailure
            }
            if !plan.authorizationBoundaryUnavailable {
                if let generation = try await maskCachedHealthDataIfNeeded(
                    for: metric,
                    plan: plan,
                    through: now,
                    using: repository,
                    onScanGenerationAdvanced: { scanGeneration = $0 }
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
                    using: repository,
                    onScanGenerationsAdvanced: { generations in
                        if let generation = generations[metric] { scanGeneration = generation }
                    }
                )
                scanGeneration = generations[metric] ?? scanGenerationByMetric[metric, default: 0]
            }
            let workoutOutcome = try await syncWorkouts(
                repository: repository,
                now: now,
                plan: plan,
                scanGeneration: scanGeneration,
                onScanGenerationAdvanced: { scanGeneration = $0 }
            )
            scanGeneration = workoutOutcome.generation
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            let pendingEffortDays = try repository.pendingHealthSampleDays(
                stream: HealthMetricID.workoutEffort.rawValue
            )
            if workoutOutcome.hasChanges || !pendingEffortDays.isEmpty {
                _ = try await sync(stream: .workoutEffort, using: repository, now: now)
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
            }
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
                if let analysisStart = HealthDataWindowPolicy.analysisStart(through: now, calendar: Calendar.autoupdatingCurrent) {
                    try? await markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                }
                throw error
            }
            if !plan.authorizationBoundaryUnavailable {
                if let generation = try await maskCachedHealthDataIfNeeded(
                    for: metric,
                    plan: plan,
                    through: now,
                    using: repository,
                    onScanGenerationAdvanced: { scanGeneration = $0 }
                ) {
                    scanGeneration = generation
                }
            }
            if plan.authorizationBoundaryUnavailable {
                let generations = try await prepareHealthKitSnapshotRebuild(
                    for: [metric],
                    from: plan.targetStart,
                    through: now,
                    using: repository,
                    onScanGenerationsAdvanced: { generations in
                        if let generation = generations[metric] { scanGeneration = generation }
                    }
                )
                scanGeneration = generations[metric] ?? scanGenerationByMetric[metric, default: 0]
            }
            do {
                try await syncAggregate(
                    metric,
                    repository: repository,
                    now: now,
                    plan: plan,
                    scanGeneration: scanGeneration
                )
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch {
                if !plan.authorizationBoundaryUnavailable {
                    try? await markHealthWindowUnknown(metric, from: plan.targetStart, through: now, using: repository)
                }
                throw error
            }
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
                let planningFailure = error
                let analysisStart = HealthDataWindowPolicy.analysisStart(
                    through: now,
                    calendar: Calendar.autoupdatingCurrent
                ) ?? now
                do {
                    let rebuiltGeneration = try await prepareTargetedStreamRebuild(
                        metric,
                        from: analysisStart,
                        through: now,
                        using: repository,
                        onScanGenerationAdvanced: { scanGeneration = $0 }
                    )
                    scanGeneration = rebuiltGeneration
                } catch {
                    await leaveStreamUnknownAndRetryable(
                        metric,
                        stream: metric.rawValue,
                        from: analysisStart,
                        through: now,
                        using: repository
                    )
                    throw error
                }
                throw planningFailure
            }
            if !plan.authorizationBoundaryUnavailable {
                if let generation = try await maskCachedHealthDataIfNeeded(
                    for: metric,
                    plan: plan,
                    through: now,
                    using: repository,
                    onScanGenerationAdvanced: { scanGeneration = $0 }
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
                    using: repository,
                    onScanGenerationsAdvanced: { generations in
                        if let generation = generations[metric] { scanGeneration = generation }
                    }
                )
                scanGeneration = generations[metric] ?? scanGenerationByMetric[metric, default: 0]
            }
            let rebuiltScanGeneration = try await syncSamples(
                metric,
                repository: repository,
                now: now,
                plan: plan,
                scanGeneration: scanGeneration,
                onScanGenerationAdvanced: { scanGeneration = $0 }
            )
            scanGeneration = rebuiltScanGeneration
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            return scanGeneration
        }
        return scanGeneration
    }

    private func makeWindowPlan(
        for metric: HealthMetricID,
        now: Date
    ) async throws -> WindowPlan {
        let calendar = Calendar.autoupdatingCurrent
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
                PerformanceSignposts.event("Health.AuthorizationBoundaryUnavailable")
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

    private func incrementalAggregatePlan(
        _ plan: WindowPlan,
        cursor: HealthKitCursorSnapshot?,
        lookbackDays: Int?,
        now: Date
    ) -> WindowPlan {
        guard let lookbackDays,
              lookbackDays > 0,
              let cursor,
              cursor.lastSuccessfulAt != nil else { return plan }
        let calendar = Calendar.autoupdatingCurrent
        let lastSyncDay = min(calendar.startOfDay(for: cursor.updatedAt), calendar.startOfDay(for: now))
        guard let overlapStart = calendar.date(
            byAdding: .day,
            value: -(lookbackDays - 1),
            to: lastSyncDay
        ) else { return plan }
        let targetStart = max(plan.targetStart, overlapStart)
        return WindowPlan(
            targetStart: targetStart,
            queryStart: HealthDataWindowPolicy.effectiveStart(
                policyStart: targetStart,
                authorizationStart: plan.authorizationStart
            ),
            authorizationStart: plan.authorizationStart,
            authorizationBoundaryUnavailable: plan.authorizationBoundaryUnavailable
        )
    }

    private func anchorPolicyStart(for metric: HealthMetricID, targetStart: Date) -> Date {
        guard metric == .sleepAnalysis else { return targetStart }
        let calendar = Calendar.autoupdatingCurrent
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
        scanGeneration: UInt64,
        readRecordCounter: HealthSyncReadRecordCounter? = nil,
        onScanGenerationAdvanced: ((UInt64) -> Void)? = nil
    ) async throws -> WorkoutSyncOutcome {
        var currentGeneration = scanGeneration
        var didRecoverInvalidAnchor = false
        var didRebaselineUnverifiedScope = false
        var hasChangesAcrossScans = false
        while true {
            do {
                let hasChanges = try await syncWorkoutPages(
                    repository: repository,
                    now: now,
                    plan: plan,
                    scanGeneration: currentGeneration,
                    readRecordCounter: readRecordCounter
                )
                hasChangesAcrossScans = hasChangesAcrossScans || hasChanges
                if !didRebaselineUnverifiedScope,
                   try requiresFullWorkoutScopeRebaseline(
                       repository: repository,
                       plan: plan,
                       through: now
                   ) {
                    didRebaselineUnverifiedScope = true
                    currentGeneration = try await prepareTargetedStreamRebuild(
                        .workout,
                        from: plan.queryStart,
                        through: now,
                        using: repository,
                        onScanGenerationAdvanced: onScanGenerationAdvanced
                    )
                    continue
                }
                return WorkoutSyncOutcome(
                    generation: currentGeneration,
                    hasChanges: hasChangesAcrossScans
                )
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch let error as HealthStoreClientError where error == .invalidAnchor && !didRecoverInvalidAnchor {
                didRecoverInvalidAnchor = true
                do {
                    let rebuiltGeneration = try await prepareTargetedStreamRebuild(
                        .workout,
                        from: plan.queryStart,
                        through: now,
                        using: repository,
                        onScanGenerationAdvanced: onScanGenerationAdvanced
                    )
                    currentGeneration = rebuiltGeneration
                } catch {
                    await leaveStreamUnknownAndRetryable(
                        .workout,
                        stream: "workouts",
                        from: plan.targetStart,
                        through: now,
                        using: repository
                    )
                    throw error
                }
            } catch {
                await leaveStreamUnknownAndRetryable(
                    .workout,
                    stream: "workouts",
                    from: plan.targetStart,
                    through: now,
                    using: repository
                )
                throw error
            }
        }
    }

    private func requiresFullWorkoutScopeRebaseline(
        repository: any HealthSyncRepository,
        plan: WindowPlan,
        through now: Date
    ) throws -> Bool {
        guard !plan.authorizationBoundaryUnavailable,
              let cursor = try repository.cursorSnapshot(for: "workouts"),
              cursor.anchorData != nil else { return false }
        let start = min(cursor.lookbackStart ?? plan.queryStart, plan.queryStart)
        let calendar = Calendar.autoupdatingCurrent
        let firstFullyAuthorizedDay = plan.authorizationStart.map {
            HealthDataWindowPolicy.firstFullyAuthorizedDay(
                for: .workout,
                authorizationStart: $0,
                calendar: calendar
            )
        }
        let queryStartDay = calendar.startOfDay(for: start)
        let firstFullyQueriedDay = start == queryStartDay
            ? queryStartDay
            : (calendar.date(byAdding: .day, value: 1, to: queryStartDay) ?? queryStartDay)
        let coverageStart = max(
            firstFullyQueriedDay,
            firstFullyAuthorizedDay ?? firstFullyQueriedDay
        )
        let throughDay = calendar.startOfDay(for: now)
        guard coverageStart <= throughDay else { return false }
        let hasVerifiedCoverage = try repository.hasAvailableHealthReadState(
            for: .workout,
            from: coverageStart,
            through: throughDay
        )
        guard !hasVerifiedCoverage else { return false }
        let persistedEvidenceStart = max(
            queryStartDay,
            calendar.startOfDay(for: plan.authorizationStart ?? start)
        )
        return try repository.hasImportedHealthKitWorkout(
            from: persistedEvidenceStart,
            through: now
        )
    }

    private func syncWorkoutPages(
        repository: any HealthSyncRepository,
        now: Date,
        plan: WindowPlan,
        scanGeneration: UInt64,
        readRecordCounter: HealthSyncReadRecordCounter?
    ) async throws -> Bool {
        let cursor = try repository.cursorSnapshot(for: "workouts")
        let start = min(cursor?.lookbackStart ?? plan.queryStart, plan.queryStart)
        var anchor = cursor?.anchorData
        let isFullHistoryQuery = anchor == nil
        let calendar = Calendar.autoupdatingCurrent
        let allowedStart = HealthDataWindowPolicy.effectiveStart(
            policyStart: start,
            authorizationStart: plan.authorizationStart
        )
        let firstFullyAuthorizedDay = plan.authorizationStart.map {
            HealthDataWindowPolicy.firstFullyAuthorizedDay(
                for: .workout,
                authorizationStart: $0,
                calendar: calendar
            )
        }
        var latestWorkoutsByUUID: [UUID: WorkoutSnapshot] = [:]
        var deletedUUIDs = Set<UUID>()

        while true {
            let page = try await healthStore.workoutChanges(from: start, after: anchor)
            readRecordCounter?.add(page.added.count + page.deletedObjectIDs.count)
            try ensureCurrentScanGeneration(scanGeneration, for: .workout)
            guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
            guard nextAnchor != anchor
                    || (!page.hasMore && page.added.isEmpty && page.deletedObjectIDs.isEmpty) else {
                throw HealthStoreClientError.invalidAnchor
            }
            // HealthKit evaluates limited-history authorization at the sample's
            // end date, so a workout may start before the boundary and still be
            // readable when its end date is within the authorized range.
            let allowedWorkouts = page.added.filter {
                $0.startedAt.addingTimeInterval($0.duration) >= allowedStart
            }
            for workout in allowedWorkouts {
                deletedUUIDs.remove(workout.healthKitUUID)
                latestWorkoutsByUUID[workout.healthKitUUID] = workout
            }
            for deletedUUID in page.deletedObjectIDs {
                latestWorkoutsByUUID.removeValue(forKey: deletedUUID)
                deletedUUIDs.insert(deletedUUID)
            }
            if !page.hasMore {
                var availableDays = Set<Date>()
                let authorizedScopeEvidence = latestWorkoutsByUUID.values.filter {
                    $0.startedAt <= now
                }
                let queryStartDay = calendar.startOfDay(for: start)
                let firstFullyQueriedDay = start == queryStartDay
                    ? queryStartDay
                    : (calendar.date(byAdding: .day, value: 1, to: queryStartDay) ?? queryStartDay)
                let coverageStart = max(
                    firstFullyQueriedDay,
                    firstFullyAuthorizedDay ?? firstFullyQueriedDay
                )
                let throughDay = calendar.startOfDay(for: now)
                var previouslyVerifiedScope = false
                if !isFullHistoryQuery,
                   !plan.authorizationBoundaryUnavailable,
                   coverageStart <= throughDay {
                    let lastClosedDay = calendar.date(
                        byAdding: .day,
                        value: -1,
                        to: throughDay
                    ) ?? throughDay
                    // Check only the range that was already closed before this
                    // incremental query. Including the new as-of day would
                    // reject a valid prior marker and force a full rebaseline
                    // every day. If the scope starts today, there is no closed
                    // prior range to extend; keep the pre-existing as-of state.
                    let previouslyCoveredThroughDay = coverageStart <= lastClosedDay
                        ? lastClosedDay
                        : nil
                    let persistedEvidenceStart = max(
                        calendar.startOfDay(for: start),
                        calendar.startOfDay(for: plan.authorizationStart ?? start)
                    )
                    let hasPreviouslyVerifiedCoverage: Bool
                    if let previouslyCoveredThroughDay {
                        hasPreviouslyVerifiedCoverage = try repository.hasAvailableHealthReadState(
                            for: .workout,
                            from: coverageStart,
                            through: previouslyCoveredThroughDay
                        )
                    } else {
                        hasPreviouslyVerifiedCoverage = false
                    }
                    if hasPreviouslyVerifiedCoverage {
                        previouslyVerifiedScope = try repository.hasImportedHealthKitWorkout(
                            from: persistedEvidenceStart,
                            through: now
                        )
                    }
                }

                let canVerifyThroughNow = !plan.authorizationBoundaryUnavailable && (
                    isFullHistoryQuery
                        ? !authorizedScopeEvidence.isEmpty
                        : previouslyVerifiedScope
                )
                if canVerifyThroughNow, coverageStart <= throughDay {
                    // A non-empty full query establishes a durable scope marker
                    // in the same transaction as its anchor and imported records.
                    // Later complete incremental pages can extend that verified
                    // scope through their sync time only while both the marker and
                    // a persisted imported HealthKit workout remain in range.
                    // The current day is available only as of `now`; that does not
                    // claim its remaining hours are complete or mean the user rested.
                    // An empty full query has no marker and stays unknown because
                    // HealthKit cannot distinguish no data from denied access.
                    availableDays.formUnion(HealthDataWindowPolicy.days(
                        from: coverageStart,
                        through: throughDay,
                        calendar: calendar
                    ))
                }
                var readStateUpdates = Dictionary(
                    uniqueKeysWithValues: availableDays.map { ($0, HealthReadState.available) }
                )
                if !canVerifyThroughNow, coverageStart <= throughDay {
                    // Persist the current day as unknown when the incremental
                    // query cannot prove HealthKit read scope. A manual workout
                    // must not turn missing HealthKit coverage into an implicit
                    // available state.
                    readStateUpdates[throughDay] = .dataUnavailableOrReadScopeUnknown
                }
                try await repository.applyImportedWorkouts(
                    latestWorkoutsByUUID.values.sorted {
                        $0.healthKitUUID.uuidString < $1.healthKitUUID.uuidString
                    },
                    deletedHealthKitUUIDs: deletedUUIDs.sorted { $0.uuidString < $1.uuidString },
                    nextAnchorData: nextAnchor,
                    lookbackStart: start,
                    stream: "workouts",
                    readStateUpdates: readStateUpdates
                )
                return !latestWorkoutsByUUID.isEmpty || !deletedUUIDs.isEmpty
            }
            anchor = nextAnchor
        }
    }

    private func leaveStreamUnknownAndRetryable(
        _ metric: HealthMetricID,
        stream: String,
        from start: Date,
        through end: Date,
        using repository: any HealthSyncRepository
    ) async {
        try? await markHealthWindowUnknown(metric, from: start, through: end, using: repository)
        try? await repository.resetHealthKitCursor(for: stream)
    }

    private func prepareTargetedStreamRebuild(
        _ metric: HealthMetricID,
        from requestedStart: Date,
        through end: Date,
        using repository: any HealthSyncRepository,
        onScanGenerationAdvanced: ((UInt64) -> Void)? = nil
    ) async throws -> UInt64 {
        let stream = metric == .workout ? "workouts" : metric.rawValue
        let cursor: HealthKitCursorSnapshot?
        do {
            cursor = try repository.cursorSnapshot(for: stream)
        } catch {
            // Even a cursor read failure means we cannot establish which cache
            // rows belong to the anchored window. Keep export closed until a
            // later successful targeted purge/rebaseline.
            _ = onHealthCachePurgeWillBegin?()
            throw error
        }
        let purgeStart = min(cursor?.lookbackStart ?? requestedStart, requestedStart)
        let generations = try await prepareHealthKitSnapshotRebuild(
            for: [metric],
            from: purgeStart,
            through: end,
            using: repository,
            onScanGenerationsAdvanced: { updated in
                if let generation = updated[metric] {
                    onScanGenerationAdvanced?(generation)
                }
            }
        )
        let generation = generations[metric] ?? scanGenerationByMetric[metric, default: 0]
        onScanGenerationAdvanced?(generation)
        return generation
    }

    private func syncAggregate(
        _ metric: HealthMetricID,
        repository: any HealthSyncRepository,
        now: Date,
        plan: WindowPlan,
        scanGeneration: UInt64,
        readRecordCounter: HealthSyncReadRecordCounter? = nil
    ) async throws {
        let stream = metric.rawValue
        let calendar = Calendar.autoupdatingCurrent
        let buckets = try await healthStore.aggregate(HealthAggregateRequest(
            metric: metric,
            startDate: plan.queryStart,
            endDate: now,
            timezoneIdentifier: calendar.timeZone.identifier
        ))
        readRecordCounter?.add(buckets.count)
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
            lookbackStart: plan.targetStart,
            through: now,
            lastSuccessfulAt: now
        )
    }

    private func syncSamples(
        _ metric: HealthMetricID,
        repository: any HealthSyncRepository,
        now: Date,
        plan: WindowPlan,
        scanGeneration: UInt64,
        readRecordCounter: HealthSyncReadRecordCounter? = nil,
        onScanGenerationAdvanced: ((UInt64) -> Void)? = nil
    ) async throws -> UInt64 {
        var currentGeneration = scanGeneration
        var didRecoverInvalidAnchor = false
        while true {
            do {
                try await syncSamplePages(
                    metric,
                    repository: repository,
                    now: now,
                    plan: plan,
                    scanGeneration: currentGeneration,
                    readRecordCounter: readRecordCounter
                )
                return currentGeneration
            } catch let error as HealthSyncSupersededError {
                throw error
            } catch let error as HealthStoreClientError where error == .invalidAnchor && !didRecoverInvalidAnchor {
                didRecoverInvalidAnchor = true
                do {
                    let rebuiltGeneration = try await prepareTargetedStreamRebuild(
                        metric,
                        from: plan.queryStart,
                        through: now,
                        using: repository,
                        onScanGenerationAdvanced: onScanGenerationAdvanced
                    )
                    currentGeneration = rebuiltGeneration
                } catch {
                    await leaveStreamUnknownAndRetryable(
                        metric,
                        stream: metric.rawValue,
                        from: plan.targetStart,
                        through: now,
                        using: repository
                    )
                    throw error
                }
            } catch {
                await leaveStreamUnknownAndRetryable(
                    metric,
                    stream: metric.rawValue,
                    from: plan.targetStart,
                    through: now,
                    using: repository
                )
                throw error
            }
        }
    }

    private func syncSamplePages(
        _ metric: HealthMetricID,
        repository: any HealthSyncRepository,
        now: Date,
        plan: WindowPlan,
        scanGeneration: UInt64,
        readRecordCounter: HealthSyncReadRecordCounter?
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
            readRecordCounter?.add(page.samples.count + page.deletedSampleIDs.count)
            try ensureCurrentScanGeneration(scanGeneration, for: metric)
            guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
            guard nextAnchor != anchor
                    || (!page.hasMore && page.samples.isEmpty && page.deletedSampleIDs.isEmpty) else {
                throw HealthStoreClientError.invalidAnchor
            }
            let allowedStart = HealthDataWindowPolicy.effectiveStart(
                policyStart: start,
                authorizationStart: plan.authorizationStart
            )
            // HealthKit authorizes limited-history samples by end date. Keep
            // returned samples that overlap the boundary instead of dropping
            // them solely because they began before it.
            let allowedPage = HealthSamplePage(
                samples: page.samples.filter { $0.endDate >= allowedStart },
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
                scanGeneration: scanGeneration,
                readRecordCounter: readRecordCounter
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
        let calendar = Calendar.autoupdatingCurrent
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
        scanGeneration: UInt64,
        readRecordCounter: HealthSyncReadRecordCounter? = nil
    ) async throws -> [HealthSampleDaySnapshot] {
        let calendar = Calendar.autoupdatingCurrent
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
                readRecordCounter?.add(page.samples.count + page.deletedSampleIDs.count)
                try ensureCurrentScanGeneration(scanGeneration, for: metric)
                guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
                guard nextAnchor != anchor
                        || (!page.hasMore && page.samples.isEmpty && page.deletedSampleIDs.isEmpty) else {
                    throw HealthStoreClientError.invalidAnchor
                }
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
