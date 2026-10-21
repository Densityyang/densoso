import Foundation
import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class DailyMetricsProjectionFingerprintTests: XCTestCase {
    func testUnchangedFingerprintSkipsWriteButPendingLegacyMetricIsReprojected() throws {
        let (_, context) = try makeContext()
        let day = Calendar.current.startOfDay(for: Date())

        try DailyMetricsProjector.reproject(on: day, in: context)
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        let sentinel = Date(timeIntervalSince1970: 1_234_567)
        metric.computedAt = sentinel
        try context.save()

        try DailyMetricsProjector.reproject(on: day, in: context)

        XCTAssertEqual(metric.computedAt, sentinel)

        metric.requiresRecompute = true
        metric.computedAt = sentinel
        try context.save()
        try DailyMetricsProjector.reproject(on: day, in: context)

        XCTAssertNotEqual(metric.computedAt, sentinel)
        XCTAssertFalse(metric.requiresRecompute)
    }

    func testSourceCursorProfileAndGoalRevisionsChangeProjectionFingerprint() throws {
        let (_, context) = try makeContext()
        let day = Calendar.current.startOfDay(for: Date())

        try DailyMetricsProjector.reproject(on: day, in: context)
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)

        let meal = MealRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000881")!,
            date: day,
            totalCaloriesKcal: 420,
            proteinG: 24,
            fatG: 12,
            carbsG: 55
        )
        context.insert(meal)
        try reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        context.insert(HealthKitImportCursor(
            stream: "activeEnergy",
            anchorData: Data([1, 2, 3]),
            lastSuccessfulAt: Date(),
            lookbackStart: day.addingTimeInterval(-86_400)
        ))
        try reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        context.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: day,
            dateOfBirth: Calendar.current.date(byAdding: .year, value: -34, to: day),
            biologicalSex: BiologicalSex.male.rawValue,
            heightCm: 174,
            weightKg: 72,
            activityLevel: ActivityLevel.moderate.rawValue,
            source: ProfileSource.userEdited.rawValue,
            createdAt: day.addingTimeInterval(1)
        ))
        try reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        let futureGoal = GoalProfileRecord(
            profileKey: "primary",
            dailyDeficitKcal: 250,
            dailyProteinGrams: 110,
            effectiveFrom: day.addingTimeInterval(2)
        )
        context.insert(futureGoal)
        try reprojectAndAssertFingerprintUnchanged(day: day, metric: metric, in: context)

        futureGoal.dailyDeficitKcal = 300
        futureGoal.dailyProteinGrams = 120
        futureGoal.effectiveFrom = day
        futureGoal.updatedAt = day.addingTimeInterval(3)
        try reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        futureGoal.targetWeightKilograms = 64
        futureGoal.dailyDeficitKcal = 325
        futureGoal.dailyProteinGrams = 125
        try reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        let fingerprintContext = try DailyMetricsProjectionFingerprint.context(
            on: day,
            inputs: DailyMetricsProjectionInputReader.read(on: day, in: context),
            profileRevision: try EffectiveProfileRevisionReader.latest(
                in: context,
                profileKey: "primary",
                effectiveAt: day
            ),
            weightObservations: [],
            in: context
        )
        let baseVersionFingerprint = CaloricEngine.projectionFingerprint(
            day: day,
            meals: [],
            workouts: [],
            profile: nil,
            weight: nil,
            context: fingerprintContext
        )
        let changedAlgorithmFingerprint = CaloricEngine.projectionFingerprint(
            day: day,
            meals: [],
            workouts: [],
            profile: nil,
            weight: nil,
            context: DailyMetricsProjectionFingerprintContext(
                sourceRecordRevisions: fingerprintContext.sourceRecordRevisions,
                healthKitCursorRevisions: fingerprintContext.healthKitCursorRevisions,
                profileRevision: fingerprintContext.profileRevision,
                goalRevision: fingerprintContext.goalRevision,
                algorithmVersion: "calorie-accounting-next"
            )
        )

        XCTAssertNotEqual(baseVersionFingerprint, changedAlgorithmFingerprint)
    }

    func testWorkoutEnergyAndProvenanceChangesProjectionFingerprint() {
        let day = Calendar.current.startOfDay(for: Date())
        let workout = WorkoutRecord(
            date: day,
            type: "walking",
            durationMinutes: 30,
            estimatedCaloriesBurned: 110,
            intensity: "moderate",
            workoutOrigin: "healthKit",
            energySource: "healthKit"
        )
        let initial = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [workout],
            effectiveProfile: nil,
            effectiveWeight: nil
        )

        workout.estimatedCaloriesBurned = 180
        workout.intensity = "vigorous"
        workout.workoutOrigin = "userEntered"
        workout.energySource = "userEntered"
        let changed = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [workout],
            effectiveProfile: nil,
            effectiveWeight: nil
        )

        XCTAssertNotEqual(initial.sourceFingerprint, changed.sourceFingerprint)
    }

    private func reprojectAndAssertFingerprintChanged(
        day: Date,
        metric: DailyMetrics,
        in context: ModelContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let previousFingerprint = metric.sourceFingerprint
        try DailyMetricsProjector.reproject(on: day, in: context)
        XCTAssertNotEqual(metric.sourceFingerprint, previousFingerprint, file: file, line: line)
    }

    private func reprojectAndAssertFingerprintUnchanged(
        day: Date,
        metric: DailyMetrics,
        in context: ModelContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let previousFingerprint = metric.sourceFingerprint
        try DailyMetricsProjector.reproject(on: day, in: context)
        XCTAssertEqual(metric.sourceFingerprint, previousFingerprint, file: file, line: line)
    }

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(versionedSchema: DensosoSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(UserProfile())
        try context.save()
        return (container, context)
    }
}
