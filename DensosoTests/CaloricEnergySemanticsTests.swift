import XCTest
@testable import Densoso

@MainActor
final class CaloricEnergySemanticsTests: XCTestCase {
    func testMeasuredActiveEnergyIsNotAddedToWorkoutEnergy() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = UserProfile(
            biologicalSex: "female",
            dateOfBirth: Date(timeIntervalSince1970: 315_532_800),
            heightCm: 165,
            weightKg: 60,
            activityLevel: "moderate"
        )
        let workout = WorkoutRecord(date: day, type: "running", durationMinutes: 60, estimatedCaloriesBurned: 420)

        let withoutWorkout = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [],
            userProfile: profile,
            healthKitActiveEnergyKcal: 510,
            healthKitRestingEnergyKcal: 1_420
        )
        let withWorkout = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [workout],
            userProfile: profile,
            healthKitActiveEnergyKcal: 510,
            healthKitRestingEnergyKcal: 1_420
        )

        XCTAssertEqual(withoutWorkout.activeCaloriesKcal, 510)
        XCTAssertEqual(withWorkout.activeCaloriesKcal, 510)
        XCTAssertEqual(withoutWorkout.bmrKcal, 1_420)
        XCTAssertEqual(withWorkout.totalExpenditureKcal, 1_930)
        XCTAssertEqual(withWorkout.workoutCount, 1)
    }

    func testWorkoutPresenceDoesNotChangeEstimatedActiveEnergyFallback() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = UserProfile(activityLevel: "active")
        let workout = WorkoutRecord(date: day, type: "cycling", durationMinutes: 45, estimatedCaloriesBurned: 300)

        let withoutWorkout = CaloricEngine.computeDailyMetrics(date: day, meals: [], workouts: [], userProfile: profile)
        let withWorkout = CaloricEngine.computeDailyMetrics(date: day, meals: [], workouts: [workout], userProfile: profile)

        XCTAssertEqual(withWorkout.activeCaloriesKcal, withoutWorkout.activeCaloriesKcal)
        XCTAssertEqual(withWorkout.totalExpenditureKcal, withoutWorkout.totalExpenditureKcal)
        XCTAssertEqual(withWorkout.workoutCount, 1)
    }
}
