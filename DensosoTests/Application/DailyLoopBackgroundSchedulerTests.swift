import XCTest
@testable import Densoso

final class DailyLoopBackgroundSchedulerTests: XCTestCase {
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
}
