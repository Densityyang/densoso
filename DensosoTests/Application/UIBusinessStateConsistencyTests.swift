import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class UIBusinessStateConsistencyTests: XCTestCase {
    func testManualAndVoiceFailuresKeepDraftAndNewerDraftIsNeverCleared() {
        let manual = VoiceCommandEnvelope.Source.manualText
        let voice = VoiceCommandEnvelope.Source.iPhoneSpeechAnalyzer
        for source in [manual, voice] {
            XCTAssertFalse(ChatComposerDraftPolicy.canClearAfterRequest(
                currentText: "吃了午饭",
                currentSource: source,
                submittedText: "吃了午饭",
                submittedSource: source,
                requestSucceeded: false,
                retainForReview: false
            ))
        }
        XCTAssertFalse(ChatComposerDraftPolicy.canClearAfterRequest(
            currentText: "新输入",
            currentSource: manual,
            submittedText: "旧输入",
            submittedSource: manual,
            requestSucceeded: true,
            retainForReview: false
        ))
        XCTAssertTrue(ChatComposerDraftPolicy.canClearAfterRequest(
            currentText: "已完成输入",
            currentSource: manual,
            submittedText: "已完成输入",
            submittedSource: manual,
            requestSucceeded: true,
            retainForReview: false
        ))
    }

    func testDashboardInvalidatesForExternalDailyMetricsInsertUpdateAndDelete() throws {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let metric = DailyMetrics(date: Date(timeIntervalSince1970: 1_800_000_000))
        context.insert(metric)
        let identifier = metric.persistentModelID
        for key in [
            ModelContext.NotificationKey.insertedIdentifiers,
            ModelContext.NotificationKey.updatedIdentifiers,
            ModelContext.NotificationKey.deletedIdentifiers,
        ] {
            let notification = Notification(
                name: ModelContext.didSave,
                object: nil,
                userInfo: [key: Set([identifier])]
            )
            XCTAssertTrue(DashboardScreen.containsDashboardProjectionChanges(notification))
        }
        XCTAssertFalse(DashboardScreen.containsDashboardProjectionChanges(
            Notification(name: ModelContext.didSave, object: nil)
        ))
    }

    func testFakeClockExpiresPhoneDailyLoopAndWatchPendingActionAtSameBoundary() throws {
        struct FakeClock {
            var now: Date
            mutating func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
        }
        var clock = FakeClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let expiry = clock.now.addingTimeInterval(60)
        let action = PendingAction(
            id: UUID(),
            idempotencyKey: "fake-clock-action",
            clientRequestID: UUID(),
            createdAt: clock.now,
            expiresAt: expiry,
            payload: .dailyCheckIn(DailyCheckIn(
                occurredAt: clock.now,
                energy: .typical,
                stress: .low,
                subjectiveSleep: .fair
            )),
            state: .pending
        )

        XCTAssertEqual(PendingActionExpirationPolicy.activeActions([action], asOf: clock.now), [action])
        XCTAssertTrue(PendingActionExpirationPolicy.isActive(expiresAt: expiry, asOf: clock.now))
        let activeDailyLoop = DailyLoopSnapshotComposer().compose(
            asOf: clock.now,
            dailyBrief: nil,
            pendingActions: [action],
            workoutPlans: []
        )
        XCTAssertEqual(activeDailyLoop.pendingActions.count, 1)

        clock.advance(by: 60)
        XCTAssertTrue(PendingActionExpirationPolicy.activeActions([action], asOf: clock.now).isEmpty)
        XCTAssertFalse(PendingActionExpirationPolicy.isActive(expiresAt: expiry, asOf: clock.now))
        let expiredDailyLoop = DailyLoopSnapshotComposer().compose(
            asOf: clock.now,
            dailyBrief: nil,
            pendingActions: [action],
            workoutPlans: []
        )
        XCTAssertTrue(expiredDailyLoop.pendingActions.isEmpty)

        let watchSummary = WatchPendingActionSummary(
            actionID: action.id,
            title: action.payload.title,
            summary: action.payload.summary,
            expiresAt: action.expiresAt
        )
        let snapshot = WatchTodaySnapshot(
            summary: "stale action is filtered at read time",
            domains: [],
            pendingActions: [watchSummary],
            acknowledgedMessageIDs: []
        )
        XCTAssertTrue(snapshot.activePendingActions(asOf: clock.now).isEmpty)
    }
}
