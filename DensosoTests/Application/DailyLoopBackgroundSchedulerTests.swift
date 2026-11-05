import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

final class DailyLoopBackgroundSchedulerTests: XCTestCase {
    @MainActor
    func testFailedRecoveryReschedulePreservesPreviousRegularTask() throws {
        let defaults = try makeScheduleDefaults()
        let oldDate = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(6 * 60 * 60)
        let oldRequest = DailyLoopBackgroundTaskRequest(
            identifier: DailyLoopBackgroundScheduler.taskIdentifier,
            earliestBeginDate: oldDate,
            reason: .regular
        )
        let fake = FakeBackgroundTaskScheduler(pendingRequest: oldRequest)
        seed(oldRequest, in: defaults)
        let controller = makeScheduleController(client: fake, defaults: defaults)
        fake.submissionError = FakeBackgroundTaskSchedulerError.rejected

        XCTAssertThrowsError(try controller.submit(DailyLoopBackgroundTaskRequest(
            identifier: DailyLoopBackgroundScheduler.taskIdentifier,
            earliestBeginDate: oldDate.addingTimeInterval(-5 * 60 * 60),
            reason: .healthSyncRecovery
        )))

        XCTAssertEqual(fake.pendingRequest, oldRequest)
        XCTAssertEqual(controller.nextRefreshEarliestAt, oldDate)
        XCTAssertEqual(controller.nextRefreshReason, .regular)
        XCTAssertEqual(defaults.object(forKey: "dailyLoop.nextRefreshEarliestAt") as? Date, oldDate)
        XCTAssertEqual(defaults.string(forKey: "dailyLoop.nextRefreshReason"), DailyLoopBackgroundRefreshReason.regular.rawValue)
    }

    @MainActor
    func testFailedRegularReschedulePreservesPreviousRecoveryTask() throws {
        let defaults = try makeScheduleDefaults()
        let oldDate = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(15 * 60)
        let oldRequest = DailyLoopBackgroundTaskRequest(
            identifier: DailyLoopBackgroundScheduler.taskIdentifier,
            earliestBeginDate: oldDate,
            reason: .projectionRecovery
        )
        let fake = FakeBackgroundTaskScheduler(pendingRequest: oldRequest)
        seed(oldRequest, in: defaults)
        let controller = makeScheduleController(client: fake, defaults: defaults)
        fake.submissionError = FakeBackgroundTaskSchedulerError.rejected

        XCTAssertThrowsError(try controller.submit(DailyLoopBackgroundTaskRequest(
            identifier: DailyLoopBackgroundScheduler.taskIdentifier,
            earliestBeginDate: oldDate.addingTimeInterval(6 * 60 * 60),
            reason: .regular
        )))

        XCTAssertEqual(fake.pendingRequest, oldRequest)
        XCTAssertEqual(controller.nextRefreshEarliestAt, oldDate)
        XCTAssertEqual(controller.nextRefreshReason, .projectionRecovery)
        XCTAssertEqual(defaults.object(forKey: "dailyLoop.nextRefreshEarliestAt") as? Date, oldDate)
        XCTAssertEqual(defaults.string(forKey: "dailyLoop.nextRefreshReason"), DailyLoopBackgroundRefreshReason.projectionRecovery.rawValue)
    }

    @MainActor
    func testSuccessfulReplacementUpdatesPersistedScheduleAtomically() throws {
        let defaults = try makeScheduleDefaults()
        let oldRequest = DailyLoopBackgroundTaskRequest(
            identifier: DailyLoopBackgroundScheduler.taskIdentifier,
            earliestBeginDate: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(6 * 60 * 60),
            reason: .regular
        )
        let newRequest = DailyLoopBackgroundTaskRequest(
            identifier: DailyLoopBackgroundScheduler.taskIdentifier,
            earliestBeginDate: oldRequest.earliestBeginDate.addingTimeInterval(-5 * 60 * 60),
            reason: .historicalRecompute
        )
        let fake = FakeBackgroundTaskScheduler(pendingRequest: oldRequest)
        seed(oldRequest, in: defaults)
        let controller = makeScheduleController(client: fake, defaults: defaults)

        try controller.submit(newRequest)

        XCTAssertEqual(fake.pendingRequest, newRequest)
        XCTAssertEqual(controller.nextRefreshEarliestAt, newRequest.earliestBeginDate)
        XCTAssertEqual(controller.nextRefreshReason, .historicalRecompute)
        XCTAssertEqual(defaults.object(forKey: "dailyLoop.nextRefreshEarliestAt") as? Date, newRequest.earliestBeginDate)
        XCTAssertEqual(defaults.string(forKey: "dailyLoop.nextRefreshReason"), DailyLoopBackgroundRefreshReason.historicalRecompute.rawValue)
    }

    func testEarlierRefreshRequestIsPreservedAcrossLaterNormalScheduling() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fifteenMinutes = now.addingTimeInterval(15 * 60)
        let sixHours = now.addingTimeInterval(6 * 60 * 60)

        XCTAssertFalse(DailyLoopBackgroundSchedulePolicy.shouldReplace(
            existingEarliestAt: fifteenMinutes,
            requestedEarliestAt: sixHours
        ))
        XCTAssertTrue(DailyLoopBackgroundSchedulePolicy.shouldReplace(
            existingEarliestAt: sixHours,
            requestedEarliestAt: fifteenMinutes
        ))
        XCTAssertFalse(DailyLoopBackgroundSchedulePolicy.shouldReplace(
            existingEarliestAt: sixHours,
            requestedEarliestAt: sixHours
        ))
        XCTAssertTrue(DailyLoopBackgroundSchedulePolicy.shouldReplace(
            existingEarliestAt: nil,
            requestedEarliestAt: sixHours
        ))
        XCTAssertEqual(DailyLoopBackgroundRefreshReason.regular.earliestBeginInterval, 6 * 60 * 60)
        XCTAssertEqual(DailyLoopBackgroundRefreshReason.historicalRecompute.earliestBeginInterval, 15 * 60)
        XCTAssertEqual(DailyLoopBackgroundRefreshReason.healthSyncRecovery.earliestBeginInterval, 15 * 60)
        XCTAssertEqual(DailyLoopBackgroundRefreshReason.projectionRecovery.earliestBeginInterval, 15 * 60)
        XCTAssertEqual(
            DailyLoopBackgroundRefreshReason(rawValue: DailyLoopBackgroundRefreshReason.healthSyncRecovery.rawValue),
            .healthSyncRecovery
        )
    }

    func testExpirationAndCompletionAreIdempotentAndLateExpirationDoesNotCancelNextWork() {
        var reportedResults: [Bool] = []
        var scheduledCancellations = 0
        let taskBox = BackgroundRefreshTaskBox(completion: { reportedResults.append($0) })

        XCTAssertTrue(taskBox.expire { scheduledCancellations += 1 })
        XCTAssertFalse(taskBox.expire { scheduledCancellations += 1 })

        XCTAssertTrue(taskBox.isExpired)
        XCTAssertEqual(scheduledCancellations, 1)

        taskBox.complete(success: true)
        taskBox.complete(success: true)

        XCTAssertEqual(reportedResults, [false])
        XCTAssertFalse(taskBox.canCancelActiveRefresh)

        taskBox.expire { scheduledCancellations += 1 }

        XCTAssertEqual(scheduledCancellations, 1)
        XCTAssertEqual(reportedResults, [false])

        var completedFirstResults: [Bool] = []
        var lateCancellations = 0
        let completedFirstBox = BackgroundRefreshTaskBox(
            completion: { completedFirstResults.append($0) }
        )

        completedFirstBox.complete(success: true)
        XCTAssertFalse(completedFirstBox.expire { lateCancellations += 1 })

        XCTAssertEqual(completedFirstResults, [true])
        XCTAssertEqual(lateCancellations, 0)
        XCTAssertFalse(completedFirstBox.canCancelActiveRefresh)
    }

    @MainActor
    func testNoHealthAuthorizationRunsLocalRecomputeAndPublishesSnapshot() async throws {
        var syncCount = 0
        var localPreparationCount = 0
        var recomputeBatchSize: Int?
        var notificationCount = 0
        var watchRefreshCount = 0
        let operations = makeOperations(
            syncHealth: { _ in
                syncCount += 1
                return Self.successfulSyncResult
            },
            prepareLocalHealthCache: { _ in localPreparationCount += 1 },
            recomputeMetrics: { _, batchSize, _ in
                recomputeBatchSize = batchSize
                return HistoricalMetricsRecomputeResult(
                    processedCount: 1,
                    hasMoreEligibleWork: false,
                    stoppedEarly: false
                )
            },
            updateNotifications: { _ in notificationCount += 1 },
            refreshWatchContext: { watchRefreshCount += 1 }
        )
        let scheduler = try makeLifecycleScheduler(operations: operations, isHealthAuthorized: false)
        let taskResults = await runOneScheduledRefresh(scheduler)

        XCTAssertEqual(taskResults, [true])
        XCTAssertEqual(syncCount, 0)
        XCTAssertEqual(localPreparationCount, 1)
        XCTAssertEqual(recomputeBatchSize, 10)
        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(watchRefreshCount, 1)
        XCTAssertEqual(scheduler.nextRefreshReason, .regular)
    }

    @MainActor
    func testPartialHealthSyncFailureSchedulesRecoveryAfterSuccessfulWork() async throws {
        var refreshCount = 0
        var syncCount = 0
        let operations = makeOperations(
            syncHealth: { _ in
                syncCount += 1
                return syncCount == 1
                    ? HealthSyncResult(
                        completedStreams: [.stepCount],
                        failedStreams: [.heartRate: Self.healthFailure(.heartRate)]
                    )
                    : Self.successfulSyncResult
            },
            refreshHealthBrief: { refreshCount += 1 }
        )
        let scheduler = try makeLifecycleScheduler(operations: operations, isHealthAuthorized: true)
        let taskResults = await runOneScheduledRefresh(scheduler)

        XCTAssertEqual(taskResults, [false])
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(scheduler.nextRefreshReason, .healthSyncRecovery)
        XCTAssertEqual(scheduler.lastError, "部分 HealthKit 数据将在后续刷新时重试。")

        let retryResults = await runOneScheduledRefresh(scheduler)
        XCTAssertEqual(retryResults, [true])
        XCTAssertEqual(syncCount, 2)
        XCTAssertEqual(refreshCount, 2)
        XCTAssertEqual(scheduler.nextRefreshReason, .regular)
        XCTAssertNil(scheduler.lastError)
    }

    @MainActor
    func testRemainingHistoricalWorkSchedulesAnotherBackgroundRun() async throws {
        let operations = makeOperations(
            recomputeMetrics: { _, _, _ in
                HistoricalMetricsRecomputeResult(
                    processedCount: 10,
                    hasMoreEligibleWork: true,
                    stoppedEarly: false
                )
            }
        )
        let scheduler = try makeLifecycleScheduler(operations: operations, isHealthAuthorized: false)

        _ = await runOneScheduledRefresh(scheduler)

        XCTAssertEqual(scheduler.nextRefreshReason, .historicalRecompute)
    }

    @MainActor
    func testHealthBriefRefreshFailureSchedulesProjectionRecovery() async throws {
        var snapshotCount = 0
        var refreshAttemptCount = 0
        let operations = makeOperations(
            refreshHealthBrief: {
                refreshAttemptCount += 1
                if refreshAttemptCount == 1 { throw LifecycleFailure.injected }
            },
            makeSnapshot: {
                snapshotCount += 1
                return Self.snapshot
            }
        )
        let scheduler = try makeLifecycleScheduler(operations: operations, isHealthAuthorized: false)
        let taskResults = await runOneScheduledRefresh(scheduler)

        XCTAssertEqual(taskResults, [false])
        XCTAssertEqual(snapshotCount, 1)
        XCTAssertEqual(scheduler.nextRefreshReason, .projectionRecovery)
        XCTAssertNotNil(scheduler.lastError)

        let retryResults = await runOneScheduledRefresh(scheduler)
        XCTAssertEqual(retryResults, [true])
        XCTAssertEqual(refreshAttemptCount, 2)
        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(scheduler.nextRefreshReason, .regular)
        XCTAssertNil(scheduler.lastError)
    }

    @MainActor
    func testTaskExpirationCancelsRecomputeAndStopsLaterRefreshStages() async throws {
        var enteredRecompute = false
        var recomputeObservedStop = false
        var briefRefreshCount = 0
        let operations = makeOperations(
            recomputeMetrics: { _, _, shouldStop in
                enteredRecompute = true
                while !shouldStop() { await Task.yield() }
                recomputeObservedStop = shouldStop()
                return HistoricalMetricsRecomputeResult(
                    processedCount: 0,
                    hasMoreEligibleWork: true,
                    stoppedEarly: true
                )
            },
            refreshHealthBrief: { briefRefreshCount += 1 }
        )
        let scheduler = try makeLifecycleScheduler(operations: operations, isHealthAuthorized: false)
        var taskResults: [Bool] = []
        let taskBox = BackgroundRefreshTaskBox(completion: { taskResults.append($0) })
        let refreshTask = Task { @MainActor in
            await scheduler.runScheduledRefresh(taskBox: taskBox, now: Self.fixedNow)
        }
        try await waitUntil { enteredRecompute }

        XCTAssertTrue(taskBox.expire { refreshTask.cancel() })
        await refreshTask.value

        XCTAssertTrue(recomputeObservedStop)
        XCTAssertEqual(taskResults, [false])
        XCTAssertEqual(briefRefreshCount, 0)
    }

    @MainActor
    private func makeScheduleDefaults() throws -> UserDefaults {
        let suiteName = "DailyLoopBackgroundSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    private func makeLifecycleScheduler(
        operations: DailyLoopBackgroundRefreshOperations,
        isHealthAuthorized: Bool
    ) throws -> DailyLoopBackgroundScheduler {
        let schema = Schema(versionedSchema: DensosoSchemaV15.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return DailyLoopBackgroundScheduler(
            modelContainer: container,
            operations: operations,
            isHealthAuthorized: { isHealthAuthorized },
            backgroundTaskScheduler: FakeBackgroundTaskScheduler(),
            scheduleDefaults: try makeScheduleDefaults(),
            initiallyRegistered: true
        )
    }

    @MainActor
    private func makeOperations(
        syncHealth: @escaping @MainActor (HealthRepository) async throws -> HealthSyncResult = { _ in
            HealthSyncResult(completedStreams: HealthKitSyncCoordinator.observedStreams, failedStreams: [:])
        },
        prepareLocalHealthCache: @escaping @MainActor (HealthRepository) async throws -> Void = { _ in },
        recomputeMetrics: @escaping DailyLoopBackgroundRefreshOperations.Recompute = { _, _, _ in
            HistoricalMetricsRecomputeResult(processedCount: 0, hasMoreEligibleWork: false, stoppedEarly: false)
        },
        refreshHealthBrief: @escaping @MainActor () async throws -> Void = {},
        makeSnapshot: @escaping @MainActor () async throws -> DailyLoopSnapshot = {
            DailyLoopSnapshot(dayStart: Date(), timezoneIdentifier: "UTC", phase: .morning)
        },
        updateNotifications: @escaping @MainActor (DailyLoopSnapshot) async -> Void = { _ in },
        refreshWatchContext: @escaping @MainActor () -> Void = {}
    ) -> DailyLoopBackgroundRefreshOperations {
        DailyLoopBackgroundRefreshOperations(
            syncHealth: syncHealth,
            prepareLocalHealthCache: prepareLocalHealthCache,
            recomputeMetrics: recomputeMetrics,
            refreshHealthBrief: refreshHealthBrief,
            makeSnapshot: makeSnapshot,
            updateNotifications: updateNotifications,
            refreshWatchContext: refreshWatchContext
        )
    }

    @MainActor
    private func runOneScheduledRefresh(_ scheduler: DailyLoopBackgroundScheduler) async -> [Bool] {
        var taskResults: [Bool] = []
        let taskBox = BackgroundRefreshTaskBox(completion: { taskResults.append($0) })
        await scheduler.runScheduledRefresh(taskBox: taskBox, now: Self.fixedNow)
        return taskResults
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private static var snapshot: DailyLoopSnapshot {
        DailyLoopSnapshot(
            dayStart: fixedNow,
            timezoneIdentifier: "UTC",
            phase: .morning
        )
    }

    private static var successfulSyncResult: HealthSyncResult {
        HealthSyncResult(completedStreams: HealthKitSyncCoordinator.observedStreams, failedStreams: [:])
    }

    private static func healthFailure(_ metric: HealthMetricID) -> HealthSyncFailure {
        HealthSyncFailure(
            stream: metric,
            requestID: UUID(),
            descriptor: SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "HealthKit unavailable",
                subsystem: .healthKit,
                reason: .healthKitUnavailable
            )
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else { throw LifecycleFailure.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private func makeScheduleController(
        client: any DailyLoopBackgroundTaskScheduling,
        defaults: UserDefaults
    ) -> DailyLoopBackgroundScheduleController {
        DailyLoopBackgroundScheduleController(
            client: client,
            defaults: defaults,
            taskIdentifier: DailyLoopBackgroundScheduler.taskIdentifier,
            earliestDateKey: "dailyLoop.nextRefreshEarliestAt",
            reasonKey: "dailyLoop.nextRefreshReason"
        )
    }

    @MainActor
    private func seed(_ request: DailyLoopBackgroundTaskRequest, in defaults: UserDefaults) {
        defaults.set(request.earliestBeginDate, forKey: "dailyLoop.nextRefreshEarliestAt")
        defaults.set(request.reason.rawValue, forKey: "dailyLoop.nextRefreshReason")
    }
}

@MainActor
final class FakeBackgroundTaskScheduler: DailyLoopBackgroundTaskScheduling {
    var pendingRequest: DailyLoopBackgroundTaskRequest?
    var submissionError: Error?

    init(pendingRequest: DailyLoopBackgroundTaskRequest? = nil) {
        self.pendingRequest = pendingRequest
    }

    func submit(_ request: DailyLoopBackgroundTaskRequest) throws {
        if let submissionError { throw submissionError }
        pendingRequest = request
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        if pendingRequest?.identifier == identifier { pendingRequest = nil }
    }
}

private enum FakeBackgroundTaskSchedulerError: Error {
    case rejected
}

private enum LifecycleFailure: Error {
    case injected
    case timedOut
}
