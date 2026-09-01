import XCTest
@testable import Densoso

final class AgentBudgetTests: XCTestCase {
    func testFiveRoundsAndEightToolsAreHardLimits() throws {
        let deadline = Date(timeIntervalSince1970: 2_000)
        var tracker = AgentBudgetTracker(
            budget: AgentBudget(
                maximumProviderRounds: 5,
                maximumToolCalls: 8,
                deadline: deadline
            )
        )
        for _ in 0..<5 { try tracker.consumeProviderRound(now: deadline.addingTimeInterval(-1)) }
        XCTAssertThrowsError(try tracker.consumeProviderRound(now: deadline.addingTimeInterval(-1)))
        for _ in 0..<8 { try tracker.consumeToolCall(now: deadline.addingTimeInterval(-1)) }
        XCTAssertThrowsError(try tracker.consumeToolCall(now: deadline.addingTimeInterval(-1)))
        XCTAssertEqual(tracker.providerRounds, 5)
        XCTAssertEqual(tracker.toolCalls, 8)
    }

    func testDeadlineIsSharedAcrossRoundsAndTools() {
        var tracker = AgentBudgetTracker(
            budget: AgentBudget(deadline: Date(timeIntervalSince1970: 1_000))
        )
        XCTAssertThrowsError(
            try tracker.consumeProviderRound(now: Date(timeIntervalSince1970: 1_000))
        ) { error in
            XCTAssertEqual(error as? ProviderError, .timeout)
        }
    }
}
