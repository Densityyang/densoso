import Foundation
import XCTest
@testable import Densoso

final class DailyBriefRefreshPolicyTests: XCTestCase {
    func testActivationRefreshWaitsForInitialRefreshAndOnlyRefreshesStaleLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let cachedDay = try localDate(2026, 10, 19, 0, 0, calendar: calendar)
        let sameDayLate = try localDate(2026, 10, 19, 23, 55, calendar: calendar)
        let nextDay = try localDate(2026, 10, 20, 0, 5, calendar: calendar)

        XCTAssertFalse(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: false,
            cachedBriefDayStart: cachedDay,
            lastSuccessfulRefreshDay: nil,
            asOf: nextDay,
            calendar: calendar
        ))
        XCTAssertFalse(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            lastSuccessfulRefreshDay: nil,
            asOf: sameDayLate,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: cachedDay,
            lastSuccessfulRefreshDay: nil,
            asOf: nextDay,
            calendar: calendar
        ))
        XCTAssertFalse(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: nil,
            lastSuccessfulRefreshDay: cachedDay,
            asOf: sameDayLate,
            calendar: calendar
        ))
        XCTAssertTrue(DailyBriefRefreshPolicy.shouldRefreshAfterActivation(
            initialRefreshCompleted: true,
            cachedBriefDayStart: nil,
            lastSuccessfulRefreshDay: nil,
            asOf: nextDay,
            calendar: calendar
        ))
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
