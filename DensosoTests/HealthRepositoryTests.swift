import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HealthRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try MainActor.assumeIsolated {
            container = try ModelContainer(
                for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self, HealthSyncOutboxEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            context = ModelContext(container)
            context.insert(UserProfile())
            try context.save()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            context = nil
            container = nil
        }
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
}
