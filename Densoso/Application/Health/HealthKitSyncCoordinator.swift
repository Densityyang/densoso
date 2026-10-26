import Foundation
import DensosoDomain

@MainActor
protocol HealthSyncRepository {
    func cursorSnapshot(for stream: String) throws -> HealthKitCursorSnapshot?
    func resetHealthKitCursors() throws
    func setHealthReadState(_ state: HealthReadState, metric: HealthMetricID, days: [Date]) throws
    func maskCachedHealthDataBeforeAuthorizationBoundary(
        for metric: HealthMetricID,
        authorizationStart: Date,
        through: Date
    ) throws
    func affectedHealthSampleDays(for page: HealthSamplePage, stream: String) throws -> [Date]
    func changedHealthSampleDays(for page: HealthSamplePage, stream: String) throws -> [Date]
    func pendingHealthSampleDays(stream: String) throws -> [Date]
    func applyImportedWorkouts(
        _ snapshots: [WorkoutSnapshot],
        deletedHealthKitUUIDs: [UUID],
        nextAnchorData: Data,
        lookbackStart: Date?,
        stream: String
    ) throws
    func applyImportedHealthSamples(
        _ page: HealthSamplePage,
        stream: String,
        lastSuccessfulAt: Date,
        lookbackStart: Date?,
        replacements: [HealthSampleDaySnapshot]
    ) throws
    func applyHealthAggregates(
        _ buckets: [HealthAggregateBucket],
        metric: HealthMetricID,
        stream: String,
        lookbackStart: Date,
        lastSuccessfulAt: Date
    ) throws
}

struct HealthSyncResult: Sendable {
    let completedStreams: Set<HealthMetricID>
    let failedStreams: [HealthMetricID: HealthSyncFailure]

    var hasFailures: Bool { !failedStreams.isEmpty }
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
    private var observationRepository: (any HealthSyncRepository)?
    private var maskedAuthorizationBoundaryByMetric: [HealthMetricID: Date] = [:]
    var onObserverSyncCompleted: (@MainActor () async -> Void)?

    private struct WindowPlan {
        let targetStart: Date
        let queryStart: Date
        let authorizationStart: Date?
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
                    try await self.sync(stream: metric, using: repository, now: Date())
                    await self.onObserverSyncCompleted?()
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
        forceRebaseline: Bool = false
    ) async throws -> HealthSyncResult {
        guard await healthStore.isAvailable() else { throw HealthStoreClientError.unavailable }
        if forceRebaseline { maskedAuthorizationBoundaryByMetric.removeAll() }
        var windowPlans: [HealthMetricID: WindowPlan] = [:]
        var windowErrors: [HealthMetricID: Error] = [:]
        var shouldResetAnchors = forceRebaseline
        let windowedMetrics = Self.aggregateStreams.union(Self.sampleStreams).union([.workout])
        for metric in windowedMetrics.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                let plan = try await makeWindowPlan(for: metric, now: now)
                windowPlans[metric] = plan
                try maskCachedHealthDataIfNeeded(for: metric, plan: plan, through: now, using: repository)
                if Self.sampleStreams.contains(metric) || metric == .workout {
                    let stream = metric == .workout ? "workouts" : metric.rawValue
                    if requiresRebaseline(
                        cursor: try repository.cursorSnapshot(for: stream),
                        policyStart: anchorPolicyStart(for: metric, targetStart: plan.targetStart),
                        authorizationStart: plan.authorizationStart
                    ) {
                        shouldResetAnchors = true
                    }
                }
            } catch {
                windowErrors[metric] = error
                shouldResetAnchors = true
                // A failed authorization-boundary lookup cannot prove that cached
                // HealthKit values are still in scope. Hide this metric's current
                // analysis window and reset anchored cursors so a later successful
                // lookup performs a fresh bounded read instead of trusting stale
                // change history.
                if let analysisStart = HealthDataWindowPolicy.analysisStart(
                    through: now,
                    calendar: Calendar.current
                ) {
                    do {
                        try markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                    } catch {
                        windowErrors[metric] = error
                    }
                }
            }
        }
        if shouldResetAnchors { try repository.resetHealthKitCursors() }
        var completedStreams = Set<HealthMetricID>()
        var failedStreams: [HealthMetricID: HealthSyncFailure] = [:]
        do {
            if let error = windowErrors[.workout] { throw error }
            guard let plan = windowPlans[.workout] else { throw HealthStoreClientError.invalidAnchor }
            try await syncWorkouts(repository: repository, now: now, plan: plan)
            completedStreams.insert(.workout)
        } catch {
            failedStreams[.workout] = makeFailure(error, stream: .workout, requestID: requestID)
        }
        for metric in Self.aggregateStreams.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let error = windowErrors[metric] {
                failedStreams[metric] = makeFailure(error, stream: metric, requestID: requestID)
                continue
            }
            do {
                guard let plan = windowPlans[metric] else { throw HealthStoreClientError.invalidAnchor }
                try await syncAggregate(metric, repository: repository, now: now, plan: plan)
                completedStreams.insert(metric)
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
                guard let plan = windowPlans[metric] else { throw HealthStoreClientError.invalidAnchor }
                try await syncSamples(metric, repository: repository, now: now, plan: plan)
                completedStreams.insert(metric)
            } catch {
                failedStreams[metric] = makeFailure(error, stream: metric, requestID: requestID)
            }
        }
        return HealthSyncResult(completedStreams: completedStreams, failedStreams: failedStreams)
    }

    private func maskCachedHealthDataIfNeeded(
        for metric: HealthMetricID,
        plan: WindowPlan,
        through date: Date,
        using repository: any HealthSyncRepository
    ) throws {
        guard let authorizationStart = plan.authorizationStart else {
            maskedAuthorizationBoundaryByMetric.removeValue(forKey: metric)
            return
        }
        guard maskedAuthorizationBoundaryByMetric[metric] != authorizationStart else { return }
        try repository.maskCachedHealthDataBeforeAuthorizationBoundary(
            for: metric,
            authorizationStart: authorizationStart,
            through: date
        )
        maskedAuthorizationBoundaryByMetric[metric] = authorizationStart
    }

    private func markHealthWindowUnknown(
        _ metric: HealthMetricID,
        from start: Date,
        through end: Date,
        using repository: any HealthSyncRepository
    ) throws {
        try repository.setHealthReadState(
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

    private func sync(stream metric: HealthMetricID, using repository: any HealthSyncRepository, now: Date) async throws {
        guard await healthStore.isAvailable() else { return }
        if metric == .workout {
            let plan: WindowPlan
            do {
                plan = try await makeWindowPlan(for: metric, now: now)
            } catch {
                if let analysisStart = HealthDataWindowPolicy.analysisStart(through: now, calendar: Calendar.current) {
                    try? markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                }
                try repository.resetHealthKitCursors()
                throw error
            }
            try maskCachedHealthDataIfNeeded(for: metric, plan: plan, through: now, using: repository)
            if requiresRebaseline(
                cursor: try repository.cursorSnapshot(for: "workouts"),
                policyStart: plan.targetStart,
                authorizationStart: plan.authorizationStart
            ) {
                try repository.resetHealthKitCursors()
            }
            try await syncWorkouts(repository: repository, now: now, plan: plan)
        } else if Self.aggregateStreams.contains(metric) {
            let plan: WindowPlan
            do {
                plan = try await makeWindowPlan(for: metric, now: now)
            } catch {
                if let analysisStart = HealthDataWindowPolicy.analysisStart(through: now, calendar: Calendar.current) {
                    try? markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                }
                try repository.resetHealthKitCursors()
                throw error
            }
            try maskCachedHealthDataIfNeeded(for: metric, plan: plan, through: now, using: repository)
            try await syncAggregate(metric, repository: repository, now: now, plan: plan)
        } else if Self.sampleStreams.contains(metric) {
            let plan: WindowPlan
            do {
                plan = try await makeWindowPlan(for: metric, now: now)
            } catch {
                if let analysisStart = HealthDataWindowPolicy.analysisStart(through: now, calendar: Calendar.current) {
                    try? markHealthWindowUnknown(metric, from: analysisStart, through: now, using: repository)
                }
                try repository.resetHealthKitCursors()
                throw error
            }
            try maskCachedHealthDataIfNeeded(for: metric, plan: plan, through: now, using: repository)
            if requiresRebaseline(
                cursor: try repository.cursorSnapshot(for: metric.rawValue),
                policyStart: anchorPolicyStart(for: metric, targetStart: plan.targetStart),
                authorizationStart: plan.authorizationStart
            ) {
                try repository.resetHealthKitCursors()
            }
            try await syncSamples(metric, repository: repository, now: now, plan: plan)
        }
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
        if let provider = healthStore as? any HealthAuthorizationBoundaryProviding {
            authorizationStart = try await provider.earliestAuthorizedSampleDate(for: metric)
        } else {
            authorizationStart = nil
        }
        let policyStart = anchorPolicyStart(for: metric, targetStart: targetStart)
        let queryStart = HealthDataWindowPolicy.effectiveStart(
            policyStart: policyStart,
            authorizationStart: authorizationStart
        )
        return WindowPlan(
            targetStart: targetStart,
            queryStart: queryStart,
            authorizationStart: authorizationStart
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
        plan: WindowPlan
    ) async throws {
        let cursor = try repository.cursorSnapshot(for: "workouts")
        let start = min(cursor?.lookbackStart ?? plan.queryStart, plan.queryStart)
        var anchor = cursor?.anchorData
        try repository.setHealthReadState(
            .dataUnavailableOrReadScopeUnknown,
            metric: .workout,
            days: workoutDaysBeforeAuthorization(plan: plan, through: now)
        )
        while true {
            let page = try await healthStore.workoutChanges(from: start, after: anchor)
            guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
            let allowedStart = HealthDataWindowPolicy.effectiveStart(
                policyStart: start,
                authorizationStart: plan.authorizationStart
            )
            let allowedWorkouts = page.added.filter { $0.startedAt >= allowedStart }
            try repository.applyImportedWorkouts(
                allowedWorkouts,
                deletedHealthKitUUIDs: page.deletedObjectIDs,
                nextAnchorData: nextAnchor,
                lookbackStart: start,
                stream: "workouts"
            )
            try repository.setHealthReadState(
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
        plan: WindowPlan
    ) async throws {
        let stream = metric.rawValue
        let calendar = Calendar.current
        let buckets = try await healthStore.aggregate(HealthAggregateRequest(
            metric: metric,
            startDate: plan.queryStart,
            endDate: now,
            timezoneIdentifier: calendar.timeZone.identifier
        ))
        let coveredBuckets = bucketsWithAuthorizationUnknowns(
            buckets,
            plan: plan,
            through: now,
            calendar: calendar
        )
        try repository.applyHealthAggregates(
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
        plan: WindowPlan
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
            let affectedDays = try repository.affectedHealthSampleDays(for: allowedPage, stream: stream)
                .filter { $0 >= plan.targetStart }
            let replacements = try await requerySampleDays(
                metric: metric,
                days: affectedDays,
                plan: plan,
                through: now
            )
            let authorizationUnknowns = isFirstPage
                ? sampleDaysBeforeAuthorization(metric: metric, plan: plan, through: now)
                : []
            try repository.applyImportedHealthSamples(
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

    private func workoutDaysBeforeAuthorization(plan: WindowPlan, through date: Date) -> [Date] {
        guard let authorizationStart = plan.authorizationStart else { return [] }
        let calendar = Calendar.current
        return HealthDataWindowPolicy.days(
            from: plan.targetStart,
            through: calendar.startOfDay(for: date),
            calendar: calendar
        ).filter { $0 < authorizationStart }
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
        through date: Date
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
