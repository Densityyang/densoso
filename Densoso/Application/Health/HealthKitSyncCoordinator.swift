import Foundation
import DensosoDomain

@MainActor
protocol HealthSyncRepository {
    func cursorSnapshot(for stream: String) throws -> HealthKitCursorSnapshot?
    func resetHealthKitCursors() throws
    func affectedHealthSampleDays(for page: HealthSamplePage, stream: String) throws -> [Date]
    func applyImportedWorkouts(
        _ snapshots: [WorkoutSnapshot],
        deletedHealthKitUUIDs: [UUID],
        nextAnchorData: Data,
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
    let failedStreams: [HealthMetricID: String]

    var hasFailures: Bool { !failedStreams.isEmpty }
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
    var onObserverSyncCompleted: (@MainActor () async -> Void)?

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
        forceRebaseline: Bool = false
    ) async throws -> HealthSyncResult {
        guard await healthStore.isAvailable() else { throw HealthStoreClientError.unavailable }
        if forceRebaseline { try repository.resetHealthKitCursors() }
        var completedStreams = Set<HealthMetricID>()
        var failedStreams: [HealthMetricID: String] = [:]
        do {
            try await syncWorkouts(repository: repository)
            completedStreams.insert(.workout)
        } catch {
            failedStreams[.workout] = String(String(describing: error).prefix(300))
        }
        for metric in Self.aggregateStreams.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                try await syncAggregate(metric, repository: repository, now: now)
                completedStreams.insert(metric)
            } catch {
                failedStreams[metric] = String(String(describing: error).prefix(300))
            }
        }
        for metric in Self.sampleStreams.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                try await syncSamples(metric, repository: repository, now: now)
                completedStreams.insert(metric)
            } catch {
                failedStreams[metric] = String(String(describing: error).prefix(300))
            }
        }
        return HealthSyncResult(completedStreams: completedStreams, failedStreams: failedStreams)
    }

    private func sync(stream metric: HealthMetricID, using repository: any HealthSyncRepository, now: Date) async throws {
        guard await healthStore.isAvailable() else { return }
        if metric == .workout {
            try await syncWorkouts(repository: repository)
        } else if Self.aggregateStreams.contains(metric) {
            try await syncAggregate(metric, repository: repository, now: now)
        } else if Self.sampleStreams.contains(metric) {
            try await syncSamples(metric, repository: repository, now: now)
        }
    }

    private func syncWorkouts(repository: any HealthSyncRepository) async throws {
        var anchor = try repository.cursorSnapshot(for: "workouts")?.anchorData
        while true {
            let page = try await healthStore.workoutChanges(after: anchor)
            guard let nextAnchor = page.nextAnchorData else { throw HealthStoreClientError.invalidAnchor }
            try repository.applyImportedWorkouts(
                page.added,
                deletedHealthKitUUIDs: page.deletedObjectIDs,
                nextAnchorData: nextAnchor,
                stream: "workouts"
            )
            if !page.hasMore { return }
            guard nextAnchor != anchor else { throw HealthStoreClientError.invalidAnchor }
            anchor = nextAnchor
        }
    }

    private func syncAggregate(
        _ metric: HealthMetricID,
        repository: any HealthSyncRepository,
        now: Date
    ) async throws {
        let stream = metric.rawValue
        let cursor = try repository.cursorSnapshot(for: stream)
        let calendar = Calendar.current
        let start = cursor?.lookbackStart
            ?? calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))
            ?? now
        let buckets = try await healthStore.aggregate(HealthAggregateRequest(
            metric: metric,
            startDate: start,
            endDate: now,
            timezoneIdentifier: calendar.timeZone.identifier
        ))
        try repository.applyHealthAggregates(
            buckets,
            metric: metric,
            stream: stream,
            lookbackStart: start,
            lastSuccessfulAt: now
        )
    }

    private func syncSamples(
        _ metric: HealthMetricID,
        repository: any HealthSyncRepository,
        now: Date
    ) async throws {
        let stream = metric.rawValue
        let cursor = try repository.cursorSnapshot(for: stream)
        let calendar = Calendar.current
        let start = cursor?.lookbackStart
            ?? calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))
            ?? now
        var anchor = cursor?.anchorData
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
            let affectedDays = try repository.affectedHealthSampleDays(for: page, stream: stream)
            let replacements = try await requerySampleDays(
                metric: metric,
                days: affectedDays
            )
            try repository.applyImportedHealthSamples(
                page,
                stream: stream,
                lastSuccessfulAt: now,
                lookbackStart: start,
                replacements: replacements
            )
            if !page.hasMore { return }
            guard nextAnchor != anchor else { throw HealthStoreClientError.invalidAnchor }
            anchor = nextAnchor
        } while true
    }

    private func requerySampleDays(
        metric: HealthMetricID,
        days: [Date]
    ) async throws -> [HealthSampleDaySnapshot] {
        let calendar = Calendar.current
        var replacements: [HealthSampleDaySnapshot] = []
        for date in days.sorted() {
            let day = calendar.startOfDay(for: date)
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
            var samples: [HealthSampleSnapshot] = []
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
                samples.append(contentsOf: page.samples)
                if !page.samples.isEmpty { readState = .available }
                else if samples.isEmpty { readState = page.readState }
                if !page.hasMore { break }
                guard nextAnchor != anchor else { throw HealthStoreClientError.invalidAnchor }
                anchor = nextAnchor
            }
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
