import Foundation
import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class DailyMetricsProjectionFingerprintTests: XCTestCase {
    func testProjectionInputReaderUsesExplicitTimezoneForDayBoundaries() async throws {
        let (_, context) = try makeContext()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var shanghai = utc
        shanghai.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let requestedInstant = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 4, minute: 30)))
        let earlierMealDate = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 20)))
        let laterMealDate = try XCTUnwrap(utc.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 8)))
        context.insert(MealRecord(date: earlierMealDate, totalCaloriesKcal: 200, proteinG: 10, fatG: 5, carbsG: 25))
        context.insert(MealRecord(date: laterMealDate, totalCaloriesKcal: 300, proteinG: 15, fatG: 8, carbsG: 35))

        let inputs = try DailyMetricsProjectionInputReader.read(
            on: requestedInstant,
            calendar: shanghai,
            in: context
        )

        XCTAssertEqual(inputs.meals.count, 2)
        XCTAssertEqual(inputs.meals.map(\.totalCaloriesKcal).reduce(0, +), 500)
    }

    func testProjectionInputReaderUsesCalendarDayAcrossDSTTransition() async throws {
        let (_, context) = try makeContext()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let dayStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let nextDayStart = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        XCTAssertEqual(nextDayStart.timeIntervalSince(dayStart), 23 * 60 * 60)
        let lastMinuteOfDay = nextDayStart.addingTimeInterval(-60)
        let firstMinuteOfNextDay = nextDayStart.addingTimeInterval(60)
        context.insert(MealRecord(date: lastMinuteOfDay, totalCaloriesKcal: 200, proteinG: 10, fatG: 5, carbsG: 25))
        context.insert(MealRecord(date: firstMinuteOfNextDay, totalCaloriesKcal: 300, proteinG: 15, fatG: 8, carbsG: 35))

        let inputs = try DailyMetricsProjectionInputReader.read(
            on: dayStart,
            calendar: calendar,
            in: context
        )

        XCTAssertEqual(inputs.meals.map(\.totalCaloriesKcal), [200])
    }

    func testProjectionInputReaderFiltersHealthKitWorkoutsByDailyReadState() async throws {
        let (_, context) = try makeContext()
        let calendar = Calendar.current
        let unknownDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let availableDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: unknownDay))
        let missingStateDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: unknownDay))
        let unknownHealthKitID = UUID(uuidString: "00000000-0000-0000-0000-000000000941")!
        let availableHealthKitID = UUID(uuidString: "00000000-0000-0000-0000-000000000942")!
        let missingStateHealthKitID = UUID(uuidString: "00000000-0000-0000-0000-000000000943")!
        let localWorkoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000944")!

        let unknownHealthKitWorkout = WorkoutRecord(
            date: unknownDay.addingTimeInterval(3_600),
            type: "limited-healthkit",
            durationMinutes: 30,
            healthKitUUID: unknownHealthKitID
        )
        unknownHealthKitWorkout.id = UUID(uuidString: "00000000-0000-0000-0000-000000000945")!
        context.insert(unknownHealthKitWorkout)
        let availableHealthKitWorkout = WorkoutRecord(
            date: availableDay.addingTimeInterval(3_600),
            type: "available-healthkit",
            durationMinutes: 40,
            healthKitUUID: availableHealthKitID
        )
        availableHealthKitWorkout.id = UUID(uuidString: "00000000-0000-0000-0000-000000000946")!
        context.insert(availableHealthKitWorkout)
        let missingStateHealthKitWorkout = WorkoutRecord(
            date: missingStateDay.addingTimeInterval(3_600),
            type: "missing-state-healthkit",
            durationMinutes: 50,
            healthKitUUID: missingStateHealthKitID
        )
        missingStateHealthKitWorkout.id = UUID(uuidString: "00000000-0000-0000-0000-000000000947")!
        context.insert(missingStateHealthKitWorkout)
        let localWorkout = WorkoutRecord(
            date: unknownDay.addingTimeInterval(7_200),
            type: "local-workout",
            durationMinutes: 25
        )
        localWorkout.id = localWorkoutID
        context.insert(localWorkout)
        for (day, readState) in [
            (unknownDay, HealthReadState.dataUnavailableOrReadScopeUnknown),
            (availableDay, .available),
        ] {
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                healthReadStates: [HealthMetricID.workout.rawValue: readState],
                algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            context.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey(day, calendar: calendar),
                timezoneID: calendar.timeZone.identifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "workout-read-state-\(day.timeIntervalSince1970)",
                algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
            ))
        }
        try context.save()

        let unknownInputs = try DailyMetricsProjectionInputReader.read(on: unknownDay, calendar: calendar, in: context)
        let availableInputs = try DailyMetricsProjectionInputReader.read(on: availableDay, calendar: calendar, in: context)
        let missingStateInputs = try DailyMetricsProjectionInputReader.read(on: missingStateDay, calendar: calendar, in: context)

        XCTAssertEqual(unknownInputs.workouts.map(\.id), [localWorkoutID])
        XCTAssertEqual(availableInputs.workouts.compactMap(\.healthKitUUID), [availableHealthKitID])
        XCTAssertTrue(missingStateInputs.workouts.isEmpty)
        try await DailyMetricsProjector.reproject(on: unknownDay, in: context)
        try await DailyMetricsProjector.reproject(on: availableDay, in: context)
        try await DailyMetricsProjector.reproject(on: missingStateDay, in: context)
        let projectedMetrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(projectedMetrics.first(where: { calendar.isDate($0.date, inSameDayAs: unknownDay) })?.workoutCount, 1)
        XCTAssertEqual(projectedMetrics.first(where: { calendar.isDate($0.date, inSameDayAs: availableDay) })?.workoutCount, 1)
        XCTAssertEqual(projectedMetrics.first(where: { calendar.isDate($0.date, inSameDayAs: missingStateDay) })?.workoutCount, 0)
    }

    func testUnchangedFingerprintSkipsWriteButPendingLegacyMetricIsReprojected() async throws {
        let (_, context) = try makeContext()
        let day = Calendar.current.startOfDay(for: Date())

        try await DailyMetricsProjector.reproject(on: day, in: context)
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        let sentinel = Date(timeIntervalSince1970: 1_234_567)
        metric.computedAt = sentinel
        try context.save()

        try await DailyMetricsProjector.reproject(on: day, in: context)

        XCTAssertEqual(metric.computedAt, sentinel)

        metric.requiresRecompute = true
        metric.computedAt = sentinel
        try context.save()
        try await DailyMetricsProjector.reproject(on: day, in: context)

        XCTAssertNotEqual(metric.computedAt, sentinel)
        XCTAssertFalse(metric.requiresRecompute)
    }

    func testSourceProfileAndGoalRevisionsChangeProjectionFingerprint() async throws {
        let (_, context) = try makeContext()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())

        try await DailyMetricsProjector.reproject(on: day, in: context)
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
        try await reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        let cursor = HealthKitImportCursor(
            stream: "activeEnergy",
            anchorData: Data([1, 2, 3]),
            lastSuccessfulAt: Date(),
            lookbackStart: day.addingTimeInterval(-86_400)
        )
        context.insert(cursor)
        try await reprojectAndAssertFingerprintUnchanged(day: day, metric: metric, in: context)

        let fingerprintAfterCursorInsert = metric.sourceFingerprint
        let sentinel = Date(timeIntervalSince1970: 1_234_567)
        metric.computedAt = sentinel
        cursor.lastSuccessfulAt = Date().addingTimeInterval(60)
        cursor.anchorData = Data([9, 8, 7])
        cursor.updatedAt = Date().addingTimeInterval(120)
        try context.save()
        try await DailyMetricsProjector.reproject(on: day, in: context)
        XCTAssertEqual(metric.sourceFingerprint, fingerprintAfterCursorInsert)
        XCTAssertEqual(metric.computedAt, sentinel)

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
        try await reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        let futureGoalDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: day))
        let futureGoal = GoalProfileRecord(
            profileKey: "primary",
            dailyDeficitKcal: 250,
            dailyProteinGrams: 110,
            effectiveFrom: futureGoalDay
        )
        context.insert(futureGoal)
        try await reprojectAndAssertFingerprintUnchanged(day: day, metric: metric, in: context)

        futureGoal.dailyDeficitKcal = 300
        futureGoal.dailyProteinGrams = 120
        futureGoal.effectiveFrom = day
        futureGoal.updatedAt = day.addingTimeInterval(3)
        try await reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        futureGoal.targetWeightKilograms = 64
        futureGoal.dailyDeficitKcal = 325
        futureGoal.dailyProteinGrams = 125
        try await reprojectAndAssertFingerprintChanged(day: day, metric: metric, in: context)

        let fingerprintContext = try DailyMetricsProjectionFingerprint.context(
            on: day,
            calendar: calendar,
            inputs: DailyMetricsProjectionInputReader.read(on: day, calendar: calendar, in: context),
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
                profileRevision: fingerprintContext.profileRevision,
                goalRevision: fingerprintContext.goalRevision,
                algorithmVersion: "calorie-accounting-next"
            )
        )

        XCTAssertNotEqual(baseVersionFingerprint, changedAlgorithmFingerprint)
    }

    func testHealthKitSnapshotValueChangesProjectionFingerprint() async throws {
        let (_, context) = try makeContext()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        try await DailyMetricsProjector.reproject(on: day, in: context)
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        let originalFingerprint = metric.sourceFingerprint

        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            activeEnergyKcal: 475,
            healthReadStates: [HealthMetricID.activeEnergy.rawValue: .available],
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(day, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "daily-metrics-fingerprint-fixture",
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        ))
        try context.save()

        try await DailyMetricsProjector.reproject(on: day, in: context)

        XCTAssertNotEqual(metric.sourceFingerprint, originalFingerprint)
        XCTAssertEqual(metric.activeEnergyKcal, 475)
    }

    func testUnrelatedHealthKitCursorDoesNotInvalidateDailyMetricsProjection() async throws {
        let (_, context) = try makeContext()
        let day = Calendar.current.startOfDay(for: Date())
        try await DailyMetricsProjector.reproject(on: day, in: context)
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        let fingerprint = metric.sourceFingerprint
        let sentinel = Date(timeIntervalSince1970: 1_234_567)
        metric.computedAt = sentinel
        context.insert(HealthKitImportCursor(
            stream: HealthMetricID.heartRateVariabilitySDNN.rawValue,
            anchorData: Data([4, 5, 6]),
            lastSuccessfulAt: Date(),
            lookbackStart: day.addingTimeInterval(-86_400)
        ))
        try context.save()

        try await DailyMetricsProjector.reproject(on: day, in: context)

        XCTAssertEqual(metric.sourceFingerprint, fingerprint)
        XCTAssertEqual(metric.computedAt, sentinel)
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
            calendar: .current,
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
            calendar: .current,
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
    ) async throws {
        let previousFingerprint = metric.sourceFingerprint
        try await DailyMetricsProjector.reproject(on: day, in: context)
        XCTAssertNotEqual(metric.sourceFingerprint, previousFingerprint, file: file, line: line)
    }

    private func reprojectAndAssertFingerprintUnchanged(
        day: Date,
        metric: DailyMetrics,
        in context: ModelContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let previousFingerprint = metric.sourceFingerprint
        try await DailyMetricsProjector.reproject(on: day, in: context)
        XCTAssertEqual(metric.sourceFingerprint, previousFingerprint, file: file, line: line)
    }

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(UserProfile())
        try context.save()
        return (container, context)
    }

    private func dayKey(_ day: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
