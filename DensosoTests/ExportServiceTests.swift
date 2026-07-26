import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ExportServiceTests: XCTestCase {
    func testRestoreReprojectsDerivedMetricsInsteadOfTrustingSerializedMetrics() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        source.insert(UserProfile())
        source.insert(MealRecord(date: date, totalCaloriesKcal: 640, proteinG: 32, fatG: 20, carbsG: 72))
        let healthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let workout = WorkoutRecord(
            date: date,
            type: "walking",
            durationMinutes: 30,
            estimatedCaloriesBurned: 130,
            healthKitUUID: healthKitUUID,
            workoutOrigin: "watchHealthKit",
            energySource: "measured",
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: "complete",
            routeStatus: "pending"
        )
        source.insert(workout)
        try source.save()

        let service = ExportService()
        let url = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: url) }

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(MealRecord(date: date, totalCaloriesKcal: 999))
        try target.save()

        let summary = try await service.restoreJSON(url: url, context: target)
        let meals = try target.fetch(FetchDescriptor<MealRecord>())
        let metrics = try target.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(summary.meals, 1)
        XCTAssertEqual(summary.workouts, 1)
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals[0].totalCaloriesKcal, 640)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 640)
        XCTAssertEqual(metrics[0].activeCaloriesKcal, 130)
        let workouts = try target.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].healthKitUUID, healthKitUUID)
        XCTAssertEqual(workouts[0].workoutOrigin, "watchHealthKit")
        XCTAssertEqual(workouts[0].energySource, "measured")
    }

    func testChecksumFailureLeavesExistingRecordsUntouched() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        source.insert(MealRecord(totalCaloriesKcal: 400))
        try source.save()

        let service = ExportService()
        let url = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: url) }
        var document = try JSONDecoder().decode(ExportService.BackupDocument.self, from: Data(contentsOf: url))
        document = .init(formatVersion: document.formatVersion, checksum: "invalid", payload: document.payload)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(MealRecord(totalCaloriesKcal: 777))
        try target.save()

        do {
            _ = try await service.restoreJSON(url: url, context: target)
            XCTFail("Expected checksum validation to fail")
        } catch {
            XCTAssertEqual(error as? ExportService.BackupError, .checksumMismatch)
        }
        let meals = try target.fetch(FetchDescriptor<MealRecord>())
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals[0].totalCaloriesKcal, 777)
    }

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, ModelContext(container))
    }
}
