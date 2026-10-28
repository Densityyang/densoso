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
            calendar: .current,
            meals: [],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight,
            healthKitActiveEnergyKcal: 510,
            healthKitRestingEnergyKcal: 1_420
        )
        let withWorkout = CaloricEngine.computeDailyMetrics(
            date: day,
            calendar: .current,
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
            date: day,
            calendar: .current,
            meals: [],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight
        )
        let withWorkout = CaloricEngine.computeDailyMetrics(
            date: day,
            calendar: .current,
            meals: [],
            workouts: [workout],
            effectiveProfile: profile,
            effectiveWeight: weight
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
            calendar: .current,
            meals: [],
            workouts: [],
            effectiveProfile: nil,
            effectiveWeight: nil
        )

        XCTAssertEqual(result.energyQuality, "unavailable")
        XCTAssertEqual(result.totalExpenditureKcal, 0)
        XCTAssertTrue(result.requiresRecompute == false)
    }

    func testEvidenceBackedZeroMealRemainsDistinctFromLegacyUnknownZero() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let measuredZero = MealRecord(
            date: day,
            totalCaloriesKcal: 0,
            evidenceData: try JSONEncoder().encode([
                EvidenceSnapshot(
                    grade: .measured,
                    sourceID: "measured-zero-energy",
                    summary: "Explicit zero-energy value."
                ),
            ])
        )
        let legacyUnknownZero = MealRecord(
            date: day,
            totalCaloriesKcal: 0,
            evidenceData: try JSONEncoder().encode([
                EvidenceSnapshot(
                    grade: .legacyPointEstimate,
                    sourceID: "swiftdata-v2",
                    summary: "Legacy point estimate."
                ),
                EvidenceSnapshot(
                    grade: .unresolved,
                    sourceID: "legacy-v2-default-zero-energy",
                    summary: "V2's default zero cannot prove zero kcal."
                ),
            ])
        )

        let measured = CaloricEngine.computeDailyMetrics(
            date: day,
            calendar: .current,
            meals: [measuredZero],
            workouts: [],
            effectiveProfile: nil,
            effectiveWeight: nil
        )
        let legacy = CaloricEngine.computeDailyMetrics(
            date: day,
            calendar: .current,
            meals: [legacyUnknownZero],
            workouts: [],
            effectiveProfile: nil,
            effectiveWeight: nil
        )

        XCTAssertEqual(measured.totalIntakeKcal, 0)
        XCTAssertTrue(try intakeIsPresent(in: measured))
        XCTAssertEqual(legacy.totalIntakeKcal, 0)
        XCTAssertFalse(try intakeIsPresent(in: legacy))
    }

    func testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = effectiveProfile(at: day, activityLevel: .moderate)
        let weight = effectiveWeight(at: day, kilograms: 60)
        let meal = MealRecord(
            date: day,
            totalCaloriesKcal: 500,
            proteinG: 30,
            fatG: 10,
            carbsG: 70,
            evidenceData: currentMealEvidenceData()
        )

        let first = CaloricEngine.computeDailyMetrics(
            date: day,
            calendar: .current,
            meals: [meal],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight
        )
        let repeated = CaloricEngine.computeDailyMetrics(
            date: day,
            calendar: .current,
            meals: [meal],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight
        )
        let changed = CaloricEngine.computeDailyMetrics(
            date: day,
            calendar: .current,
            meals: [MealRecord(
                date: day,
                totalCaloriesKcal: 520,
                proteinG: 30,
                fatG: 10,
                carbsG: 70,
                evidenceData: currentMealEvidenceData()
            )],
            workouts: [],
            effectiveProfile: profile,
            effectiveWeight: weight
        )

        XCTAssertEqual(first.sourceFingerprint, repeated.sourceFingerprint)
        XCTAssertNotEqual(first.sourceFingerprint, changed.sourceFingerprint)
    }

    func testDailyCalculationUsesExplicitTimezoneForDayBoundaries() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var shanghai = utc
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        var losAngeles = utc
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        let requestedInstant = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 4, minute: 30)))
        let earlierMealDate = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 20)))
        let laterMealDate = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8)))
        let meals = [
            MealRecord(
                date: earlierMealDate,
                totalCaloriesKcal: 200,
                proteinG: 10,
                fatG: 5,
                carbsG: 25,
                evidenceData: currentMealEvidenceData()
            ),
            MealRecord(
                date: laterMealDate,
                totalCaloriesKcal: 300,
                proteinG: 15,
                fatG: 8,
                carbsG: 35,
                evidenceData: currentMealEvidenceData()
            ),
        ]

        let shanghaiProjection = CaloricEngine.computeDailyMetrics(
            date: requestedInstant,
            calendar: shanghai,
            meals: meals,
            workouts: [],
            effectiveProfile: nil,
            effectiveWeight: nil
        )
        let losAngelesProjection = CaloricEngine.computeDailyMetrics(
            date: requestedInstant,
            calendar: losAngeles,
            meals: meals,
            workouts: [],
            effectiveProfile: nil,
            effectiveWeight: nil
        )

        XCTAssertEqual(shanghaiProjection.mealCount, 2)
        XCTAssertEqual(shanghaiProjection.totalIntakeKcal, 500)
        XCTAssertEqual(losAngelesProjection.mealCount, 1)
        XCTAssertEqual(losAngelesProjection.totalIntakeKcal, 200)
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

    private func currentMealEvidenceData() -> Data {
        let evidence = EvidenceSnapshot(
            grade: .userReported,
            sourceID: "test-current-meal",
            summary: "Regression fixture with current estimate evidence."
        )
        return try! JSONEncoder().encode([evidence])
    }

    private func intakeIsPresent(in result: DailyMetricsCalculationResult) throws -> Bool {
        let coverage = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.dataCoverageJSON.utf8)) as? [String: Any]
        )
        return try XCTUnwrap(coverage["intake"] as? Bool)
    }
}
