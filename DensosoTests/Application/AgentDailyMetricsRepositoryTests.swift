import Foundation
import DensosoDomain
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
        XCTAssertEqual(results.compactMap { $0.deficit.value?.likely }, [101, 102, 103])
        XCTAssertTrue(results.allSatisfy { $0.expenditure.availability == .observed })
        XCTAssertTrue(results.allSatisfy { $0.intake.availability == .estimated })
        XCTAssertTrue(results.allSatisfy { $0.deficit.availability == .estimated })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), countBefore)
    }

    func testRepositoryPagesAllMetricsAcrossStableDatePages() async throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let base = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let metricCount = SwiftDataAgentRepository.dailyMetricFetchBatchSize + 1
        var dates: [Date] = []
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        for index in 0..<metricCount {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: index, to: base))
            dates.append(date)
            context.insert(metric(at: date, deficit: 100 + index))
        }
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let end = try XCTUnwrap(dates.last)
        let results = try await repository.dailyMetrics(from: base, through: end)

        XCTAssertEqual(results.count, metricCount)
        XCTAssertEqual(results.map(\.date), dates)
        XCTAssertEqual(results.compactMap { $0.deficit.value?.likely }, (0..<metricCount).map { Double(100 + $0) })
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

    func testLegacyZeroScalarsMapToUnavailableInsteadOfObservedZero() {
        let metric = DailyMetrics(date: Date(), totalExpenditureKcal: 0, totalIntakeKcal: 0, deficitKcal: 0)

        let result = DailyMetricsReadModelMapper.make(metric)

        XCTAssertNil(result.expenditure.value)
        XCTAssertNil(result.deficit.value)
        XCTAssertEqual(result.expenditure.availability, .unavailable)
        XCTAssertEqual(result.deficit.availability, .unavailable)
        XCTAssertEqual(result.coverage.deficit.availableDays, 0)
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
            workoutCount: 1,
            energyQuality: "observed",
            dataCoverageJSON: #"{"intake":true,"protein":true,"fat":true,"carbs":true}"#,
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "agent-metrics-test-\(date.timeIntervalSince1970)"
        )
    }
}
