import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class HealthRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        context.insert(UserProfile())
        try context.save()
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    func testInsertAndDeleteReprojectsTheSameDay() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = HealthRepository(modelContext: context)
        let meal = MealRecord(date: date, totalCaloriesKcal: 500, proteinG: 30, fatG: 10, carbsG: 70)
        let workout = WorkoutRecord(date: date, type: "walking", durationMinutes: 30, estimatedCaloriesBurned: 120)

        try repository.insert(meal)
        try repository.insert(workout)

        var metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].mealCount, 1)
        XCTAssertEqual(metrics[0].workoutCount, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 500)
        XCTAssertEqual(metrics[0].activeCaloriesKcal, 120)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 2)

        try repository.delete(meal)
        metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].mealCount, 0)
        XCTAssertEqual(metrics[0].workoutCount, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 0)
        XCTAssertEqual(metrics[0].activeCaloriesKcal, 120)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 3)
    }

    func testImportedWorkoutDeduplicatesByHealthKitUUIDAndPersistsAnchor() throws {
        let repository = HealthRepository(modelContext: context)
        let healthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let logicalSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try WorkoutSnapshot(
            healthKitUUID: healthKitUUID,
            logicalSessionID: logicalSessionID,
            startedAt: date,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 250),
            origin: .watchHealthKit,
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: .complete
        )
        let updated = try WorkoutSnapshot(
            healthKitUUID: healthKitUUID,
            logicalSessionID: logicalSessionID,
            startedAt: date,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 275),
            origin: .watchHealthKit,
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: .complete
        )

        try repository.applyImportedWorkouts([first, updated], deletedHealthKitUUIDs: [], nextAnchorData: Data([1]))

        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].healthKitUUID, healthKitUUID)
        XCTAssertEqual(workouts[0].logicalSessionID, logicalSessionID)
        XCTAssertEqual(workouts[0].estimatedCaloriesBurned, 275)
        XCTAssertEqual(workouts[0].energySource, WorkoutEnergySource.measured.rawValue)
        XCTAssertEqual(try repository.anchorData(), Data([1]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 0)

        try repository.markImportedRouteAvailable(healthKitUUID: healthKitUUID, pointCount: 1)
        XCTAssertEqual(try repository.pendingRouteHealthKitUUIDs(), [])
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.routeStatus, "available")
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.routePointCount, 1)

        try repository.applyImportedWorkouts([], deletedHealthKitUUIDs: [healthKitUUID], nextAnchorData: Data([2]))

        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).isEmpty)
        XCTAssertEqual(try repository.anchorData(), Data([2]))
        let metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.first?.workoutCount, 0)
    }
}
