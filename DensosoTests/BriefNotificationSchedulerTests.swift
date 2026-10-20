import DensosoDomain
import XCTest
@testable import Densoso

@MainActor
final class BriefNotificationSchedulerTests: XCTestCase {
    private let suiteName = "BriefNotificationSchedulerTests.\(UUID().uuidString)"

    func testNotificationErrorsExposeSharedSafeDescriptors() {
        let denied = BriefNotificationError.authorizationDenied
        let invalidTime = BriefNotificationError.invalidTime

        XCTAssertEqual(denied.sharedErrorDescriptor.code, .actionConflict)
        XCTAssertEqual(denied.localizedDescription, denied.sharedErrorDescriptor.userMessage)
        XCTAssertEqual(invalidTime.sharedErrorDescriptor.code, .toolArgumentsInvalid)
        XCTAssertEqual(invalidTime.localizedDescription, invalidTime.sharedErrorDescriptor.userMessage)
    }

    func testNotificationsAreOffByDefaultAndRestoreDoesNotRequestPermission() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeBriefNotificationClient()
        let scheduler = BriefNotificationScheduler(client: client, defaults: defaults)

        XCTAssertFalse(scheduler.morningEnabled)
        XCTAssertFalse(scheduler.eveningEnabled)
        XCTAssertFalse(scheduler.weeklyEnabled)
        XCTAssertEqual(scheduler.morningHour, 8)
        XCTAssertEqual(scheduler.morningMinute, 0)
        XCTAssertEqual(scheduler.eveningHour, 21)
        XCTAssertEqual(scheduler.eveningMinute, 0)
        await scheduler.restoreSchedules()
        XCTAssertEqual(client.authorizationRequests, 0)
        XCTAssertTrue(client.schedules.isEmpty)
    }

    func testLegacyDailyPreferenceMigratesToMorningReminder() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "briefNotifications.daily.enabled")
        let client = FakeBriefNotificationClient()
        let scheduler = BriefNotificationScheduler(client: client, defaults: defaults)

        XCTAssertTrue(scheduler.morningEnabled)
        await scheduler.restoreSchedules()
        XCTAssertEqual(client.schedules.map(\.identifier), ["densoso.brief.morning"])
    }

    func testDeniedPermissionLeavesReminderDisabled() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeBriefNotificationClient()
        client.authorizationGranted = false
        let scheduler = BriefNotificationScheduler(client: client, defaults: defaults)

        do {
            try await scheduler.setMorningEnabled(true)
            XCTFail("Expected notification authorization denial")
        } catch {
            XCTAssertEqual(error as? BriefNotificationError, .authorizationDenied)
        }
        XCTAssertFalse(scheduler.morningEnabled)
        XCTAssertTrue(client.schedules.isEmpty)
    }

    func testMorningAndEveningTimesAreConfigurableAndCopyUsesLocalSnapshot() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeBriefNotificationClient()
        let scheduler = BriefNotificationScheduler(client: client, defaults: defaults)

        try await scheduler.setMorningEnabled(true)
        try await scheduler.setEveningEnabled(true)
        try await scheduler.setWeeklyEnabled(true)
        try await scheduler.setMorningTime(hour: 7, minute: 45)
        try await scheduler.setEveningTime(hour: 20, minute: 15)

        XCTAssertEqual(client.schedules.map(\.hour), [7, 20, 8])
        XCTAssertEqual(client.schedules.map(\.minute), [45, 15, 0])
        XCTAssertEqual(client.schedules.map(\.weekday), [nil, nil, 2])
        XCTAssertEqual(scheduler.morningHour, 7)
        XCTAssertEqual(scheduler.morningMinute, 45)
        XCTAssertEqual(scheduler.eveningHour, 20)
        XCTAssertEqual(scheduler.eveningMinute, 15)

        let snapshot = DailyLoopSnapshot(
            dayStart: Date(timeIntervalSince1970: 0),
            phase: .morning,
            todayState: DailyStateSummary(headline: "恢复处于常见范围")
        )
        await scheduler.updateSnapshot(snapshot)

        let morning = try XCTUnwrap(client.schedules.first { $0.identifier == "densoso.brief.morning" })
        let evening = try XCTUnwrap(client.schedules.first { $0.identifier == "densoso.brief.evening" })
        XCTAssertTrue(morning.body.contains("恢复处于常见范围"))
        XCTAssertTrue(evening.body.contains("恢复处于常见范围"))
        XCTAssertTrue(client.schedules.allSatisfy { !$0.body.contains("kcal") && !$0.body.contains("体重") })
    }

    func testInvalidReminderTimeIsRejected() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scheduler = BriefNotificationScheduler(client: FakeBriefNotificationClient(), defaults: defaults)

        do {
            try await scheduler.setEveningTime(hour: 24, minute: 60)
            XCTFail("Expected invalid reminder time")
        } catch {
            XCTAssertEqual(error as? BriefNotificationError, .invalidTime)
        }
        XCTAssertEqual(scheduler.eveningHour, 21)
        XCTAssertEqual(scheduler.eveningMinute, 0)
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class FakeBriefNotificationClient: BriefNotificationClient {
    struct Schedule {
        let identifier: String
        let title: String
        let body: String
        let hour: Int
        let minute: Int
        let weekday: Int?
    }

    var authorizationGranted = true
    var authorizationRequests = 0
    var schedules: [Schedule] = []

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    func schedule(identifier: String, title: String, body: String, hour: Int, minute: Int, weekday: Int?) async throws {
        let value = Schedule(identifier: identifier, title: title, body: body, hour: hour, minute: minute, weekday: weekday)
        if let index = schedules.firstIndex(where: { $0.identifier == identifier }) {
            schedules[index] = value
        } else {
            schedules.append(value)
        }
    }

    func remove(identifier: String) {
        schedules.removeAll { $0.identifier == identifier }
    }
}
