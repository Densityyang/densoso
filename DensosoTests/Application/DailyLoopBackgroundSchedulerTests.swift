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
    private func makeScheduleDefaults() throws -> UserDefaults {
        let suiteName = "DailyLoopBackgroundSchedulerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
private final class FakeBackgroundTaskScheduler: DailyLoopBackgroundTaskScheduling {
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
