import XCTest
@testable import Densoso

final class DailyLoopSnapshotRefreshQueueTests: XCTestCase {
    func testOverlappingRefreshesAreCoalescedAndHealthRefreshTakesPriority() {
        var queue = DailyLoopSnapshotRefreshQueue()

        XCTAssertEqual(queue.request(refreshHealth: false), .start(refreshHealth: false))
        XCTAssertEqual(queue.request(refreshHealth: false), .queued)
        XCTAssertEqual(queue.request(refreshHealth: true), .queued)
        XCTAssertTrue(queue.isRefreshing)

        XCTAssertEqual(queue.finishPass(), true)
        XCTAssertEqual(queue.request(refreshHealth: false), .queued)
        XCTAssertEqual(queue.finishPass(), false)
        XCTAssertNil(queue.finishPass())
        XCTAssertFalse(queue.isRefreshing)
    }

    func testRefreshCanStartAgainAfterQueuedPassesFinish() {
        var queue = DailyLoopSnapshotRefreshQueue()

        XCTAssertEqual(queue.request(refreshHealth: true), .start(refreshHealth: true))
        XCTAssertNil(queue.finishPass())
        XCTAssertEqual(queue.request(refreshHealth: false), .start(refreshHealth: false))
        XCTAssertNil(queue.finishPass())
    }
}
