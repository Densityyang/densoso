import Foundation
import XCTest
@testable import Densoso

@MainActor
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

    func testMealTextIntentDeliveryUpdatesRunningAppState() throws {
        let suiteName = "AppIntentInboxDeliveredMealTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousMealText = AppState.shared.pendingMealText

        AppIntentInbox.deliver(mealText: "晚餐：杂粮饭和豆腐", defaults: defaults)
        defer { AppState.shared.pendingMealText = previousMealText }

        XCTAssertEqual(AppState.shared.pendingMealText, "晚餐：杂粮饭和豆腐")
        XCTAssertEqual(AppIntentInbox.consumeMealText(defaults: defaults), "晚餐：杂粮饭和豆腐")
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

    func testWorkoutPlanIntentDeliveryUpdatesRunningAppState() throws {
        let suiteName = "AppIntentInboxDeliveredWorkoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousWorkoutPlan = AppState.shared.pendingWorkoutPlan
        let draft = WorkoutPlanDraft(
            name: "傍晚跑步",
            activity: .running,
            goal: .timeMinutes(25)
        )

        AppIntentInbox.deliver(workoutPlan: draft, defaults: defaults)
        defer { AppState.shared.pendingWorkoutPlan = previousWorkoutPlan }

        XCTAssertEqual(AppState.shared.pendingWorkoutPlan, draft)
        XCTAssertEqual(AppIntentInbox.consumeWorkoutPlan(defaults: defaults), draft)
        XCTAssertNil(AppIntentInbox.consumeWorkoutPlan(defaults: defaults))
    }

    func testPendingDraftInboxRestoresMealAndWorkoutOnceForColdOrActiveScene() throws {
        let suiteName = "AppIntentInboxRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousMealText = AppState.shared.pendingMealText
        let previousWorkoutPlan = AppState.shared.pendingWorkoutPlan
        let mealText = "早餐：燕麦和牛奶"
        let workoutPlan = WorkoutPlanDraft(name: "周末骑行", activity: .cycling)
        AppIntentInbox.store(mealText: mealText, defaults: defaults)
        AppIntentInbox.store(workoutPlan: workoutPlan, defaults: defaults)
        defer {
            AppState.shared.pendingMealText = previousMealText
            AppState.shared.pendingWorkoutPlan = previousWorkoutPlan
        }

        AppIntentInbox.receivePendingDrafts(defaults: defaults)

        XCTAssertEqual(AppState.shared.pendingMealText, mealText)
        XCTAssertEqual(AppState.shared.pendingWorkoutPlan, workoutPlan)
        XCTAssertNil(AppIntentInbox.consumeMealText(defaults: defaults))
        XCTAssertNil(AppIntentInbox.consumeWorkoutPlan(defaults: defaults))
    }

    func testSceneReceiveCanKeepWorkoutPlanInInboxWhileReceivingMeal() throws {
        let suiteName = "AppIntentInboxDeferredWorkoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousMealText = AppState.shared.pendingMealText
        let previousWorkoutPlan = AppState.shared.pendingWorkoutPlan
        let mealText = "午餐：鸡蛋和蔬菜"
        let workoutPlan = WorkoutPlanDraft(name: "待编辑训练", activity: .running)
        AppState.shared.pendingMealText = nil
        AppState.shared.pendingWorkoutPlan = nil
        AppIntentInbox.store(mealText: mealText, defaults: defaults)
        AppIntentInbox.store(workoutPlan: workoutPlan, defaults: defaults)
        defer {
            AppState.shared.pendingMealText = previousMealText
            AppState.shared.pendingWorkoutPlan = previousWorkoutPlan
        }

        AppIntentInbox.receivePendingDrafts(receiveWorkoutPlan: false, defaults: defaults)

        XCTAssertEqual(AppState.shared.pendingMealText, mealText)
        XCTAssertNil(AppState.shared.pendingWorkoutPlan)
        XCTAssertNil(AppIntentInbox.consumeMealText(defaults: defaults))
        XCTAssertEqual(AppIntentInbox.consumeWorkoutPlan(defaults: defaults), workoutPlan)
    }

    func testReceiveDoesNotReplaceAnAlreadyPendingWorkoutDraft() throws {
        let suiteName = "AppIntentInboxExistingWorkoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previousMealText = AppState.shared.pendingMealText
        let previousWorkoutPlan = AppState.shared.pendingWorkoutPlan
        let pendingDraft = WorkoutPlanDraft(name: "当前待编辑计划", activity: .walking)
        let inboxDraft = WorkoutPlanDraft(name: "后续计划", activity: .cycling)
        AppState.shared.pendingMealText = nil
        AppState.shared.pendingWorkoutPlan = pendingDraft
        AppIntentInbox.store(mealText: "晚餐：鱼和蔬菜", defaults: defaults)
        AppIntentInbox.store(workoutPlan: inboxDraft, defaults: defaults)
        defer {
            AppState.shared.pendingMealText = previousMealText
            AppState.shared.pendingWorkoutPlan = previousWorkoutPlan
        }

        AppIntentInbox.receivePendingDrafts(defaults: defaults)

        XCTAssertEqual(AppState.shared.pendingWorkoutPlan, pendingDraft)
        XCTAssertEqual(AppState.shared.pendingMealText, "晚餐：鱼和蔬菜")
        XCTAssertEqual(AppIntentInbox.consumeWorkoutPlan(defaults: defaults), inboxDraft)
    }

    func testMealTextHandoffPreservesExistingComposerText() {
        XCTAssertEqual(
            AppIntentInbox.mergedMealText(existing: "已有未发送内容", incoming: "系统转写草稿"),
            "已有未发送内容\n\n系统转写草稿"
        )
        XCTAssertEqual(
            AppIntentInbox.mergedMealText(existing: " \n ", incoming: "系统转写草稿"),
            "系统转写草稿"
        )
    }

    func testQueuedWorkoutPlansPersistInOrderUntilAcknowledged() throws {
        let suiteName = "AppIntentInboxQueuedWorkoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = WorkoutPlanDraft(name: "第一份排队计划", activity: .walking)
        let second = WorkoutPlanDraft(name: "第二份排队计划", activity: .cycling)

        XCTAssertTrue(AppIntentInbox.enqueueWorkoutPlan(first, defaults: defaults))
        XCTAssertTrue(AppIntentInbox.enqueueWorkoutPlan(second, defaults: defaults))
        XCTAssertEqual(AppIntentInbox.nextQueuedWorkoutPlan(defaults: defaults), first)
        XCTAssertEqual(AppIntentInbox.nextQueuedWorkoutPlan(defaults: defaults), first)

        AppIntentInbox.acknowledgeQueuedWorkoutPlan(first, defaults: defaults)
        XCTAssertEqual(AppIntentInbox.nextQueuedWorkoutPlan(defaults: defaults), second)
        AppIntentInbox.acknowledgeQueuedWorkoutPlan(second, defaults: defaults)
        XCTAssertNil(AppIntentInbox.nextQueuedWorkoutPlan(defaults: defaults))
    }

    func testWorkoutPlanQueueHasBoundedCapacity() throws {
        let suiteName = "AppIntentInboxWorkoutQueueLimitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 0..<16 {
            let draft = WorkoutPlanDraft(name: "排队计划 \(index)", activity: .walking)
            XCTAssertTrue(AppIntentInbox.enqueueWorkoutPlan(draft, defaults: defaults))
        }

        XCTAssertFalse(
            AppIntentInbox.enqueueWorkoutPlan(
                WorkoutPlanDraft(name: "超出上限", activity: .running),
                defaults: defaults
            )
        )
        XCTAssertEqual(AppIntentInbox.nextQueuedWorkoutPlan(defaults: defaults)?.name, "排队计划 0")
    }
}
