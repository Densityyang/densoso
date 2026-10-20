import Foundation
import XCTest
@testable import Densoso

final class AppIntentInboxTests: XCTestCase {
    func testSystemDestinationsRoundTripAndAreConsumedOnce() throws {
        let suiteName = "AppIntentInboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            DensosoAppIntentDestination.allCases,
            [.todayStatus, .todayGuidance, .openToday, .startRecording]
        )
        for destination in DensosoAppIntentDestination.allCases {
            AppIntentInbox.store(destination: destination, defaults: defaults)
            XCTAssertEqual(AppIntentInbox.consumeDestination(defaults: defaults), destination)
            XCTAssertNil(AppIntentInbox.consumeDestination(defaults: defaults))
        }
    }

    func testMealTextDraftIsConsumedOnceFromInjectedDefaults() throws {
        let suiteName = "AppIntentInboxMealTests.\(UUID().uuidString)"
        let emptySuiteName = "AppIntentInboxEmptyMealTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let emptyDefaults = try XCTUnwrap(UserDefaults(suiteName: emptySuiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defer { emptyDefaults.removePersistentDomain(forName: emptySuiteName) }

        AppIntentInbox.store(mealText: "午餐：米饭和青菜", defaults: defaults)

        XCTAssertNil(AppIntentInbox.consumeMealText(defaults: emptyDefaults))
        XCTAssertEqual(AppIntentInbox.consumeMealText(defaults: defaults), "午餐：米饭和青菜")
        XCTAssertNil(AppIntentInbox.consumeMealText(defaults: defaults))
    }

    func testWorkoutPlanDraftIsConsumedOnceFromInjectedDefaults() throws {
        let suiteName = "AppIntentInboxWorkoutTests.\(UUID().uuidString)"
        let emptySuiteName = "AppIntentInboxEmptyWorkoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let emptyDefaults = try XCTUnwrap(UserDefaults(suiteName: emptySuiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defer { emptyDefaults.removePersistentDomain(forName: emptySuiteName) }
        let draft = WorkoutPlanDraft(
            name: "午间步行",
            activity: .walking,
            goal: .timeMinutes(35)
        )

        AppIntentInbox.store(workoutPlan: draft, defaults: defaults)

        XCTAssertNil(AppIntentInbox.consumeWorkoutPlan(defaults: emptyDefaults))
        XCTAssertEqual(AppIntentInbox.consumeWorkoutPlan(defaults: defaults), draft)
        XCTAssertNil(AppIntentInbox.consumeWorkoutPlan(defaults: defaults))
    }
}
