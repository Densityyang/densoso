import Foundation
import DensosoDomain
@testable import Densoso

actor FakeHealthStoreClient: HealthStoreClient, HealthObserverClient, HealthAuthorizationBoundaryProviding {
    private var available = true
    private var aggregateResponses: [HealthMetricID: [HealthAggregateBucket]] = [:]
    private var aggregateFailures: Set<HealthMetricID> = []
    private var aggregateRequestLog: [HealthMetricID: [HealthAggregateRequest]] = [:]
    private var sampleResponses: [HealthMetricID: [HealthSamplePage]] = [:]
    private var sampleRequestLog: [HealthMetricID: [HealthSampleRequest]] = [:]
    private var workoutRequestStarts: [Date] = []
    private var authorizedSampleStarts: [HealthMetricID: Date] = [:]
    private var authorizationBoundaryFailures: Set<HealthMetricID> = []
    private var workoutResponses: [HealthChangePage<WorkoutSnapshot>] = []
    private var observerHandler: HealthObserverClient.UpdateHandler?
    private var observerCompletions = 0
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeFailuresRemaining = 0

    private(set) var authorizationScope: HealthAuthorizationScope?
    private(set) var backgroundStreams: Set<HealthMetricID> = []
    private(set) var attemptedWrites: [HealthWriteCommand] = []
    private(set) var successfulWrites: [HealthWriteCommand] = []
    private(set) var deletedReceipts: [HealthWriteReceipt] = []

    func setAvailable(_ value: Bool) { available = value }
    func setAggregateResponse(_ values: [HealthAggregateBucket], for metric: HealthMetricID) {
        aggregateResponses[metric] = values
    }
    func setEarliestAuthorizedSampleDate(_ date: Date, for metric: HealthMetricID) {
        authorizedSampleStarts[metric] = date
    }
    func failAuthorizationBoundaryLookup(for metric: HealthMetricID) {
        authorizationBoundaryFailures.insert(metric)
    }
    func failAggregate(for metric: HealthMetricID) { aggregateFailures.insert(metric) }
    func setSampleResponses(_ pages: [HealthSamplePage], for metric: HealthMetricID) {
        sampleResponses[metric] = pages
    }
    func setWorkoutResponses(_ pages: [HealthChangePage<WorkoutSnapshot>]) {
        workoutResponses = pages
    }
    func failNextWrites(_ count: Int) { writeFailuresRemaining = max(0, count) }

    func isAvailable() async -> Bool { available }

    func earliestAuthorizedSampleDate(for metric: HealthMetricID) async throws -> Date? {
        if authorizationBoundaryFailures.contains(metric) {
            throw HealthStoreClientError.authorizationBoundaryUnavailable
        }
        return authorizedSampleStarts[metric]
    }

    func requestAuthorization(_ scope: HealthAuthorizationScope) async throws {
        guard available else { throw HealthStoreClientError.unavailable }
        authorizationScope = scope
    }

    func aggregate(_ request: HealthAggregateRequest) async throws -> [HealthAggregateBucket] {
        guard available else { throw HealthStoreClientError.unavailable }
        aggregateRequestLog[request.metric, default: []].append(request)
        if aggregateFailures.contains(request.metric) {
            throw HealthStoreClientError.queryFailed("fake aggregate failure")
        }
        return aggregateResponses[request.metric] ?? []
    }

    func samples(_ request: HealthSampleRequest) async throws -> HealthSamplePage {
        guard available else { throw HealthStoreClientError.unavailable }
        sampleRequestLog[request.metric, default: []].append(request)
        guard var pages = sampleResponses[request.metric], !pages.isEmpty else {
            return HealthSamplePage(
                samples: [],
                nextAnchorData: request.anchorData ?? Data([0]),
                readState: .dataUnavailableOrReadScopeUnknown
            )
        }
        let page = pages.removeFirst()
        sampleResponses[request.metric] = pages
        return page
    }

    func workoutChanges(from startDate: Date, after anchor: Data?) async throws -> HealthChangePage<WorkoutSnapshot> {
        guard available else { throw HealthStoreClientError.unavailable }
        workoutRequestStarts.append(startDate)
        guard !workoutResponses.isEmpty else {
            return HealthChangePage(
                added: [],
                deletedObjectIDs: [],
                nextAnchorData: anchor ?? Data([0]),
                readState: .dataUnavailableOrReadScopeUnknown
            )
        }
        return workoutResponses.removeFirst()
    }

    func save(_ command: HealthWriteCommand) async throws -> HealthWriteReceipt {
        guard available else { throw HealthStoreClientError.unavailable }
        attemptedWrites.append(command)
        if writeFailuresRemaining > 0 {
            writeFailuresRemaining -= 1
            throw FakeHealthStoreError.transient
        }
        successfulWrites.append(command)
        let metrics: [HealthMetricID]
        switch command.payload {
        case .nutrition(let values):
            var result: [HealthMetricID] = [.dietaryEnergy]
            if values.proteinGrams != nil { result.append(.dietaryProtein) }
            if values.fatGrams != nil { result.append(.dietaryFat) }
            if values.carbohydrateGrams != nil { result.append(.dietaryCarbohydrates) }
            metrics = result
        case .confirmedWeight:
            metrics = [.bodyMass]
        }
        return HealthWriteReceipt(
            recordID: command.recordID,
            syncIdentifier: command.syncIdentifier,
            syncVersion: command.syncVersion,
            metrics: metrics,
            sampleIDs: []
        )
    }

    func deleteOwnSample(receipt: HealthWriteReceipt) async throws {
        guard available else { throw HealthStoreClientError.unavailable }
        deletedReceipts.append(receipt)
    }

    func enableBackgroundDelivery(for streams: Set<HealthMetricID>) async throws {
        guard available else { throw HealthStoreClientError.unavailable }
        backgroundStreams = streams
    }

    func startObserving(
        _ streams: Set<HealthMetricID>,
        onUpdate: @escaping HealthObserverClient.UpdateHandler
    ) async throws {
        guard available else { throw HealthStoreClientError.unavailable }
        observerHandler = onUpdate
    }

    func triggerObserver(_ metric: HealthMetricID) {
        observerHandler?(metric) { [weak self] in
            guard let self else { return }
            Task { await self.didCompleteObserverUpdate() }
        }
    }

    func completedObserverCount() -> Int { observerCompletions }
    func aggregateRequests(for metric: HealthMetricID) -> [HealthAggregateRequest] {
        aggregateRequestLog[metric] ?? []
    }
    func sampleRequests(for metric: HealthMetricID) -> [HealthSampleRequest] {
        sampleRequestLog[metric] ?? []
    }
    func workoutRequestStartDates() -> [Date] { workoutRequestStarts }

    func waitForObserverCompletion(after count: Int) async {
        if observerCompletions > count { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }

    private func didCompleteObserverUpdate() {
        observerCompletions += 1
        let waiters = completionWaiters
        completionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

enum FakeHealthStoreError: Error {
    case transient
}
