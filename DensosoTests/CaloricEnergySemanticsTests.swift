import DensosoDomain
import XCTest
@testable import Densoso

@MainActor
final class CaloricEnergySemanticsTests: XCTestCase {
    func testMeasuredActiveEnergyIsNotAddedToWorkoutEnergy() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = effectiveProfile(at: day, activityLevel: .moderate)
        let weight = effectiveWeight(at: day, kilograms: 60)
        let workout = WorkoutRecord(date: day, type: "running", durationMinutes: 60, estimatedCaloriesBurned: 420)

        let withoutWorkout = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight,
            healthKitActiveEnergyKcal: 510,
            healthKitRestingEnergyKcal: 1_420
        )
        let withWorkout = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [workout],
            effectiveProfile: profile,
            effectiveWeight: weight,
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
        let profile = effectiveProfile(at: day, activityLevel: .active)
        let weight = effectiveWeight(at: day, kilograms: 70)
        let workout = WorkoutRecord(date: day, type: "cycling", durationMinutes: 45, estimatedCaloriesBurned: 300)

        let withoutWorkout = CaloricEngine.computeDailyMetrics(
            date: day, meals: [], workouts: [], effectiveProfile: profile, effectiveWeight: weight
        )
        let withWorkout = CaloricEngine.computeDailyMetrics(
            date: day, meals: [], workouts: [workout], effectiveProfile: profile, effectiveWeight: weight
        )

        XCTAssertEqual(withWorkout.activeCaloriesKcal, withoutWorkout.activeCaloriesKcal)
        XCTAssertEqual(withWorkout.totalExpenditureKcal, withoutWorkout.totalExpenditureKcal)
        XCTAssertEqual(withWorkout.workoutCount, 1)
        XCTAssertEqual(withWorkout.energyQuality, "estimated")
    }

    func testMissingEffectiveProfileDoesNotInventEnergyExpenditure() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let result = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [],
            effectiveProfile: nil,
            effectiveWeight: nil
        )

        XCTAssertEqual(result.energyQuality, "unavailable")
        XCTAssertEqual(result.totalExpenditureKcal, 0)
        XCTAssertTrue(result.requiresRecompute == false)
    }

    func testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = effectiveProfile(at: day, activityLevel: .moderate)
        let weight = effectiveWeight(at: day, kilograms: 60)
        let meal = MealRecord(date: day, totalCaloriesKcal: 500, proteinG: 30, fatG: 10, carbsG: 70)

        let first = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [meal],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight
        )
        let repeated = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [meal],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight
        )
        let changed = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [MealRecord(date: day, totalCaloriesKcal: 520, proteinG: 30, fatG: 10, carbsG: 70)],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight
        )

        XCTAssertEqual(first.sourceFingerprint, repeated.sourceFingerprint)
        XCTAssertNotEqual(first.sourceFingerprint, changed.sourceFingerprint)
    }

    private func effectiveProfile(at date: Date, activityLevel: ActivityLevel) -> EffectiveProfile {
        EffectiveProfile(
            profileKey: "primary",
            sourceRevisionID: UUID(),
            sourceEffectiveFrom: date.addingTimeInterval(-86_400),
            effectiveAt: date,
            dateOfBirth: Date(timeIntervalSince1970: 315_532_800),
            biologicalSex: .female,
            heightCm: 165,
            weightKg: 60,
            activityLevel: activityLevel
        )
    }

    private func effectiveWeight(at date: Date, kilograms: Double) -> EffectiveWeight {
        EffectiveWeight(
            measuredAt: date,
            kilograms: kilograms,
            source: .manual,
            confidence: 0.9
        )
    }
}
