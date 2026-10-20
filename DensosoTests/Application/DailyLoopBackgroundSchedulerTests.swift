import XCTest
@testable import Densoso

final class DailyLoopBackgroundSchedulerTests: XCTestCase {
    func testExpirationAndCompletionAreIdempotentAndLateExpirationDoesNotCancelNextWork() {
        var reportedResults: [Bool] = []
        var scheduledCancellations = 0
        let taskBox = BackgroundRefreshTaskBox(completion: { reportedResults.append($0) })

        taskBox.expire { scheduledCancellations += 1 }
        taskBox.expire { scheduledCancellations += 1 }

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
        completedFirstBox.expire { lateCancellations += 1 }

        XCTAssertEqual(completedFirstResults, [true])
        XCTAssertEqual(lateCancellations, 0)
        XCTAssertFalse(completedFirstBox.canCancelActiveRefresh)
    }
}
