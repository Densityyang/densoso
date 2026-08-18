import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class WeeklyAnalyticsServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: UserProfile.self, DailyMetrics.self, WeeklyReport.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
    }

    override func tearDown() {
        calendar = nil
        context = nil
        container = nil
        super.tearDown()
    }

    func testLoadBuildsSevenDaySeriesAndPersistsCurrentWeek() throws {
        let reference = makeDate(year: 2026, month: 7, day: 29)
        let profile = UserProfile(dailyDeficitTarget: 500)
        context.insert(profile)
        context.insert(metric(daysBefore: 0, reference: reference, deficit: 600, meals: 3, workouts: 1))
        context.insert(metric(daysBefore: 1, reference: reference, deficit: 400, meals: 2, workouts: 0))
        context.insert(metric(daysBefore: 3, reference: reference, deficit: 700, meals: 4, workouts: 1))
        try context.save()

        let snapshot = try WeeklyAnalyticsService(calendar: calendar).load(
            referenceDate: reference,
            profile: profile,
            in: context
        )

        XCTAssertEqual(snapshot.points.count, 7)
        XCTAssertEqual(snapshot.recordedDays, 3)
        XCTAssertEqual(snapshot.totalDeficitKcal, 1_700)
        XCTAssertEqual(snapshot.averageDailyDeficitKcal, 1_700.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.points.map(\.targetDeficitKcal), Array(repeating: 500, count: 7))
        XCTAssertEqual(snapshot.points.filter(\.hasData).count, 3)

        let reports = try context.fetch(FetchDescriptor<WeeklyReport>())
        XCTAssertEqual(reports.count, 1)
        // July 26 is part of the rolling seven-day snapshot, but it precedes
        // this Monday-based calendar week and must not enter its report.
        XCTAssertEqual(reports[0].weekStartDate, makeDate(year: 2026, month: 7, day: 27))
        XCTAssertEqual(reports[0].totalDeficitKcal, 1_000)
        XCTAssertEqual(reports[0].mealsCount, 5)
        XCTAssertEqual(reports[0].workoutsCount, 1)
        XCTAssertEqual(reports[0].compliance, 0.5, accuracy: 0.001)
    }

    func testMissingDaysRemainExplicitInsteadOfInventingMetrics() throws {
        let reference = makeDate(year: 2026, month: 7, day: 29)
        let snapshot = try WeeklyAnalyticsService(calendar: calendar).load(
            referenceDate: reference,
            profile: nil,
            in: context
        )

        XCTAssertFalse(snapshot.hasData)
        XCTAssertEqual(snapshot.points.count, 7)
        XCTAssertTrue(snapshot.points.allSatisfy { !$0.hasData && $0.deficitKcal == 0 })
        XCTAssertEqual(snapshot.totalDeficitKcal, 0)
    }

    private func metric(
        daysBefore: Int,
        reference: Date,
        deficit: Int,
        meals: Int,
        workouts: Int
    ) -> DailyMetrics {
        let date = calendar.date(byAdding: .day, value: -daysBefore, to: reference)!
        let metric = DailyMetrics(
            date: date,
            totalExpenditureKcal: 2_000,
            totalIntakeKcal: 2_000 - deficit,
            deficitKcal: deficit,
            proteinG: 100,
            fatG: 60,
            carbsG: 180,
            mealCount: meals,
            workoutCount: workouts
        )
        // DailyMetrics normalizes with Calendar.current. Pin the stored value to
        // this test's calendar so the assertions remain timezone-independent.
        metric.date = calendar.startOfDay(for: date)
        return metric
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
