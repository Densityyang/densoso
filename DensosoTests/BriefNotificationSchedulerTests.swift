import XCTest
@testable import Densoso

@MainActor
final class BriefNotificationSchedulerTests: XCTestCase {
    private let suiteName = "BriefNotificationSchedulerTests.\(UUID().uuidString)"

    func testNotificationsAreOffByDefaultAndRestoreDoesNotRequestPermission() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeBriefNotificationClient()
        let scheduler = BriefNotificationScheduler(client: client, defaults: defaults)

        XCTAssertFalse(scheduler.dailyEnabled)
        XCTAssertFalse(scheduler.weeklyEnabled)
        await scheduler.restoreSchedules()
        XCTAssertEqual(client.authorizationRequests, 0)
        XCTAssertTrue(client.schedules.isEmpty)
    }

    func testDeniedPermissionLeavesReminderDisabled() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeBriefNotificationClient()
        client.authorizationGranted = false
        let scheduler = BriefNotificationScheduler(client: client, defaults: defaults)

        do {
            try await scheduler.setDailyEnabled(true)
            XCTFail("Expected notification authorization denial")
        } catch {
            XCTAssertEqual(error as? BriefNotificationError, .authorizationDenied)
        }
        XCTAssertFalse(scheduler.dailyEnabled)
        XCTAssertTrue(client.schedules.isEmpty)
    }

    func testDailyAndWeeklyRemindersUseFixedLocalTimeAndPrivacySafeText() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeBriefNotificationClient()
        let scheduler = BriefNotificationScheduler(client: client, defaults: defaults)

        try await scheduler.setDailyEnabled(true)
        try await scheduler.setWeeklyEnabled(true)
        XCTAssertEqual(client.schedules.map(\.hour), [8, 8])
        XCTAssertEqual(client.schedules.map(\.weekday), [nil, 2])
        XCTAssertTrue(client.schedules.allSatisfy { !$0.body.contains("kcal") && !$0.body.contains("体重") })
        XCTAssertTrue(scheduler.dailyEnabled)
        XCTAssertTrue(scheduler.weeklyEnabled)
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
        let weekday: Int?
    }

    var authorizationGranted = true
    var authorizationRequests = 0
    var schedules: [Schedule] = []

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    func schedule(identifier: String, title: String, body: String, hour: Int, weekday: Int?) async throws {
        schedules.append(.init(identifier: identifier, title: title, body: body, hour: hour, weekday: weekday))
    }

    func remove(identifier: String) {
        schedules.removeAll { $0.identifier == identifier }
    }
}
