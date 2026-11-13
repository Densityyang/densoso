import Foundation
import XCTest
@testable import Densoso

final class DailyBriefRefreshPolicyTests: XCTestCase {
    func testActivationRefreshWaitsForInitialRefreshAndUsesValidationFreshness() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let cachedDay = try localDate(2026, 10, 19, 0, 0, calendar: calendar)
        let validatedAt = try localDate(2026, 10, 19, 8, 0, calendar: calendar)
        let sameDayLate = try localDate(2026, 10, 19, 23, 55, calendar: calendar)
        let sameDayEarly = try localDate(2026, 10, 19, 9, 0, calendar: calendar)
        let sameDayAfterExpiry = try localDate(2026, 10, 19, 15, 0, calendar: calendar)
        let successfulRefreshAt = try localDate(2026, 10, 19, 8, 0, calendar: calendar)
        let justBeforeMidnight = try localDate(2026, 10, 19, 23, 55, calendar: calendar)
        let nextDay = try localDate(2026, 10, 20, 0, 5, calendar: calendar)

        XCTAssertFalse(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: false,
            cachedBriefDayStart: cachedDay,
            validatedAt: nil,
            asOf: nextDay,
            calendar: calendar
        ))
        XCTAssertFalse(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            validatedAt: validatedAt,
            asOf: sameDayEarly,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            validatedAt: nil,
            asOf: sameDayLate,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            validatedAt: validatedAt,
            asOf: sameDayAfterExpiry,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            validatedAt: validatedAt,
            lastSuccessfulAt: justBeforeMidnight,
            asOf: nextDay,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: nil,
            validatedAt: nil,
            lastSuccessfulAt: justBeforeMidnight,
            asOf: nextDay,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: nil,
            validatedAt: validatedAt,
            asOf: sameDayLate,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: nil,
            validatedAt: nil,
            asOf: nextDay,
            calendar: calendar
        ))
        XCTAssertFalse(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: nil,
            validatedAt: nil,
            lastSuccessfulAt: successfulRefreshAt,
            asOf: sameDayEarly,
            calendar: calendar
        ))
    }

    func testFailedRefreshCanRetryAfterBackoffAndSourceChangesInvalidateFreshCache() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let cachedDay = try localDate(2026, 10, 19, 0, 0, calendar: calendar)
        let validatedAt = try localDate(2026, 10, 19, 8, 0, calendar: calendar)
        let failedAt = try localDate(2026, 10, 19, 9, 0, calendar: calendar)
        let beforeRetry = failedAt.addingTimeInterval(29)
        let afterRetry = failedAt.addingTimeInterval(30)

        XCTAssertFalse(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            validatedAt: validatedAt,
            lastFailedAt: failedAt,
            consecutiveFailures: 1,
            asOf: beforeRetry,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            validatedAt: validatedAt,
            lastFailedAt: failedAt,
            consecutiveFailures: 1,
            asOf: afterRetry,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            validatedAt: validatedAt,
            sourceFingerprintChanged: true,
            asOf: failedAt,
            calendar: calendar
        ))
        XCTAssertEqual(DailyBriefRefreshPolicy.retryBackoffInterval(failureCount: 1), 30)
        XCTAssertEqual(DailyBriefRefreshPolicy.retryBackoffInterval(failureCount: 2), 60)
        XCTAssertEqual(DailyBriefRefreshPolicy.retryBackoffInterval(failureCount: 20), 15 * 60)
    }

    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
