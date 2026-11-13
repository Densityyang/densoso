import XCTest
import DensosoDomain
@testable import Densoso

final class DailyLoopConfirmationRefreshPolicyTests: XCTestCase {
    func testEveryConfirmedHealthActionRequestsAuthoritativeHealthRefresh() {
        let actionTypes: [ActionType] = [
            .meal,
            .weight,
            .workoutPlan,
            .trainingPlan,
            .dailyCheckIn,
            .userPreference,
        ]

        for actionType in actionTypes {
            XCTAssertTrue(
                DailyLoopConfirmationRefreshPolicy.shouldRefreshHealth(afterConfirming: actionType),
                "\(actionType) changes local context used by the daily loop"
            )
        }
    }
}
