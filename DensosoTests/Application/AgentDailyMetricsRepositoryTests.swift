import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class AgentDailyMetricsRepositoryTests: XCTestCase {
    func testRepositoryFiltersToInclusiveDateRangeAndSortsResults() async throws {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let before = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: base))
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: base))
        let middle = base
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: base))
        let after = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: base))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        // Insert in a deliberately mixed order; the repository must apply both the
        // inclusive range and ascending order in the SwiftData fetch.
        [
            metric(at: end, deficit: 103),
            metric(at: after, deficit: 104),
            metric(at: before, deficit: 99),
            metric(at: middle, deficit: 102),
            metric(at: start, deficit: 101),
        ].forEach(context.insert)
        try context.save()
        let countBefore = try context.fetchCount(FetchDescriptor<DailyMetrics>())

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let results = try await repository.dailyMetrics(from: start, through: end)

        XCTAssertEqual(results.map(\.date), [start, middle, end])
        XCTAssertEqual(results.map(\.deficitKcal), [101, 102, 103])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), countBefore)
    }

    func testRepositoryReturnsEmptyForInvertedDateRange() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        let later = earlier.addingTimeInterval(86_400)

        let results = try await repository.dailyMetrics(from: later, through: earlier)
        XCTAssertTrue(results.isEmpty)
    }

    private func metric(at date: Date, deficit: Int) -> DailyMetrics {
        DailyMetrics(
            date: date,
            bmrKcal: 1_400,
            activeCaloriesKcal: 400,
            totalExpenditureKcal: 1_800,
            totalIntakeKcal: 1_800 - deficit,
            deficitKcal: deficit,
            proteinG: 80,
            fatG: 50,
            carbsG: 180,
            mealCount: 2,
            workoutCount: 1
        )
    }
}
