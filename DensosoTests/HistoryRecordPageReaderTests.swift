import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HistoryRecordPageReaderTests: XCTestCase {
    func testRecordHistoryPagesByDayAndKeepsOlderRowsReachable() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let reader = HistoryRecordPageReader()
        let startDate = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate)!
        let dateRange = HistoryRecordDateRange(startDate: startDate, endDate: endDate)
        var expectedMealIDs: [UUID] = []
        var expectedWorkoutIDs: [UUID] = []
        var expectedWeightIDs: [UUID] = []

        for index in 0..<65 {
            let recordDate = startDate.addingTimeInterval(TimeInterval(index))
            let mealID = UUID()
            context.insert(MealRecord(
                id: mealID,
                date: recordDate,
                totalCaloriesKcal: index,
                sourceActionKey: "history-page-\(index)"
            ))
            expectedMealIDs.append(mealID)

            let workout = WorkoutRecord(date: recordDate, type: "walking", durationMinutes: 30)
            context.insert(workout)
            expectedWorkoutIDs.append(workout.id)

            let weight = WeightRecord(
                sourceActionKey: "history-weight-\(index)",
                measuredAt: recordDate,
                kilograms: 70 + Double(index) / 10
            )
            context.insert(weight)
            expectedWeightIDs.append(weight.id)
        }
        context.insert(MealRecord(
            date: startDate.addingTimeInterval(-60),
            totalCaloriesKcal: 900,
            sourceActionKey: "history-outside-date"
        ))
        try context.save()

        let firstPage = try reader.meals(in: context, during: dateRange)
        XCTAssertEqual(firstPage.records.count, HistoryRecordPageReader.pageSize)
        XCTAssertTrue(firstPage.hasMore)
        let secondPage = try reader.meals(
            in: context,
            during: dateRange,
            before: try XCTUnwrap(firstPage.nextCursor)
        )
        XCTAssertEqual(secondPage.records.count, 1)
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertEqual((firstPage.records + secondPage.records).map(\.id), Array(expectedMealIDs.reversed()))

        let firstWorkoutPage = try reader.workouts(in: context, during: dateRange)
        XCTAssertEqual(firstWorkoutPage.records.count, HistoryRecordPageReader.pageSize)
        XCTAssertTrue(firstWorkoutPage.hasMore)
        let secondWorkoutPage = try reader.workouts(
            in: context,
            during: dateRange,
            before: try XCTUnwrap(firstWorkoutPage.nextCursor)
        )
        XCTAssertEqual(secondWorkoutPage.records.count, 1)
        XCTAssertFalse(secondWorkoutPage.hasMore)
        XCTAssertEqual(
            (firstWorkoutPage.records + secondWorkoutPage.records).map(\.id),
            Array(expectedWorkoutIDs.reversed())
        )

        let firstWeightPage = try reader.weights(in: context, during: dateRange)
        XCTAssertEqual(firstWeightPage.records.count, HistoryRecordPageReader.pageSize)
        XCTAssertTrue(firstWeightPage.hasMore)
        let secondWeightPage = try reader.weights(
            in: context,
            during: dateRange,
            before: try XCTUnwrap(firstWeightPage.nextCursor)
        )
        XCTAssertEqual(secondWeightPage.records.count, 1)
        XCTAssertFalse(secondWeightPage.hasMore)
        XCTAssertEqual(
            (firstWeightPage.records + secondWeightPage.records).map(\.id),
            Array(expectedWeightIDs.reversed())
        )
    }

    func testSyncSummaryCountsOutboxStatesAndFindsLatestImportWithoutLoadingRows() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<65 {
            let state: String
            switch index {
            case 0: state = "pending"
            case 1: state = "sending"
            case 2: state = "retryable"
            case 3: state = "terminal"
            default: state = "succeeded"
            }
            context.insert(HealthSyncOutboxEntry(
                operation: "deleteMeal",
                recordID: UUID(),
                idempotencyKey: "sync-summary-\(index)",
                state: state
            ))
        }
        context.insert(HealthKitImportCursor(stream: "bodyMass", lastSuccessfulAt: now))
        context.insert(HealthKitImportCursor(stream: "workouts", lastSuccessfulAt: now.addingTimeInterval(60)))
        context.insert(HealthKitImportCursor(stream: "stepCount"))
        try context.save()

        let summary = try HistoryRecordPageReader().syncSummary(in: context)

        XCTAssertEqual(summary.pendingCount, 3)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.latestSuccessfulImport, now.addingTimeInterval(60))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}
