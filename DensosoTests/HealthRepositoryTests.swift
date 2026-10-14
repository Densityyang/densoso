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
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self,
                DailyHealthSnapshotRecord.self, WeightRecord.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
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
        let activeEnergyWithoutWorkout = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first?.activeCaloriesKcal)
        try repository.insert(workout)

        var metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].mealCount, 1)
        XCTAssertEqual(metrics[0].workoutCount, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 500)
        XCTAssertEqual(metrics[0].activeCaloriesKcal, activeEnergyWithoutWorkout)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 1)

        try repository.delete(meal)
        metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].mealCount, 0)
        XCTAssertEqual(metrics[0].workoutCount, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 0)
        XCTAssertEqual(metrics[0].activeCaloriesKcal, activeEnergyWithoutWorkout)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 2)
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

        context.insert(WorkoutRecord(date: date, type: "old-copy", healthKitUUID: healthKitUUID))
        context.insert(WorkoutRecord(date: date, type: "duplicate-copy", healthKitUUID: healthKitUUID))
        try context.save()

        try repository.applyImportedWorkouts([first, updated], deletedHealthKitUUIDs: [], nextAnchorData: Data([1]))

        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].healthKitUUID, healthKitUUID)
        XCTAssertEqual(workouts[0].logicalSessionID, logicalSessionID)
        XCTAssertEqual(workouts[0].estimatedCaloriesBurned, 275)
        XCTAssertEqual(workouts[0].energySource, WorkoutEnergySource.measured.rawValue)
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([1]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).first?.routeStatus, "unavailable")

        try repository.applyImportedWorkouts([], deletedHealthKitUUIDs: [healthKitUUID], nextAnchorData: Data([2]))

        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).isEmpty)
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([2]))
        let metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.first?.workoutCount, 0)
    }

    func testCursorAndSampleProjectionRollbackTogetherWhenSaveFails() throws {
        let repository = HealthRepository(modelContext: context, willSave: { throw TestSaveError.injected })
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            metric: .bodyMass,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_000),
            value: 71.5
        )
        let page = HealthSamplePage(
            samples: [sample],
            nextAnchorData: Data([3]),
            readState: .available
        )

        XCTAssertThrowsError(try repository.applyImportedHealthSamples(page, stream: "bodyMass"))
        XCTAssertNil(try repository.cursor(for: "bodyMass"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyMetrics>()).isEmpty)
    }

    func testHealthSamplePagesUpdateDeleteAndDeduplicateByHealthKitUUID() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = HealthSampleSnapshot(id: sampleID, metric: .bodyMass, startDate: date, endDate: date, value: 70)
        let updated = HealthSampleSnapshot(id: sampleID, metric: .bodyMass, startDate: date, endDate: date, value: 71)

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [first], nextAnchorData: Data([1]), readState: .available),
            stream: "bodyMass"
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [updated, updated], nextAnchorData: Data([2]), readState: .available),
            stream: "bodyMass"
        )

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: stored.payloadData)
        XCTAssertEqual(snapshot.healthKitSamples?.count, 1)
        XCTAssertEqual(snapshot.healthKitSamples?.first?.metric, .bodyMass)
        XCTAssertEqual(snapshot.healthKitSamples?.first?.value, 71)
        XCTAssertEqual(snapshot.weightKilograms, 71)
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([2]))

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], deletedSampleIDs: [sampleID], nextAnchorData: Data([3]), readState: .available),
            stream: "bodyMass"
        )
        let afterDeletion = try decoder.decode(DailyHealthSnapshot.self, from: XCTUnwrap(
            context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first
        ).payloadData)
        XCTAssertTrue(afterDeletion.healthKitSamples?.isEmpty ?? true)
        XCTAssertNil(afterDeletion.weightKilograms)
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([3]))

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([4]), readState: .dataUnavailableOrReadScopeUnknown),
            stream: "bodyMass"
        )
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([4]))
        XCTAssertNotNil(try repository.cursor(for: "bodyMass")?.lastSuccessfulAt)

        try repository.resetHealthKitCursors()
        XCTAssertNil(try repository.cursor(for: "bodyMass")?.anchorData)
        XCTAssertNil(try repository.cursor(for: "bodyMass")?.lastSuccessfulAt)
    }

    func testUpdatedSampleMovingToAnotherDayRemovesOldProjection() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let movedDate = Calendar.current.date(byAdding: .day, value: 2, to: firstDate)!
        let first = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: firstDate,
            endDate: firstDate,
            value: 70
        )
        let moved = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: movedDate,
            endDate: movedDate,
            value: 72
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [first], nextAnchorData: Data([1]), readState: .available),
            stream: "bodyMass"
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [moved], nextAnchorData: Data([2]), readState: .available),
            stream: "bodyMass"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        let originalDay = try XCTUnwrap(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: firstDate) }))
        let movedDay = try XCTUnwrap(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: movedDate) }))
        XCTAssertTrue(originalDay.healthKitSamples?.isEmpty ?? true)
        XCTAssertNil(originalDay.weightKilograms)
        XCTAssertEqual(movedDay.healthKitSamples?.map(\.id), [sampleID])
        XCTAssertEqual(movedDay.healthKitSamples?.first?.value, 72)
        XCTAssertEqual(movedDay.weightKilograms, 72)
    }

    func testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            activeEnergyKcal: 640,
            restingEnergyKcal: 1_410,
            healthReadStates: [
                HealthMetricID.activeEnergy.rawValue: .available,
                HealthMetricID.restingEnergy.rawValue: .available,
            ],
            algorithmVersion: "v3"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey,
            timezoneID: Calendar.current.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "fixture",
            algorithmVersion: "v3"
        ))
        try context.save()

        try HealthRepository(modelContext: context).applyHealthAggregates(
            [HealthAggregateBucket(
                startDate: day,
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!,
                value: nil
            )],
            metric: .activeEnergy,
            stream: "activeEnergy",
            lookbackStart: day
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let savedSnapshot = try decoder.decode(
            DailyHealthSnapshot.self,
            from: XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first).payloadData
        )
        XCTAssertEqual(savedSnapshot.activeEnergyKcal, 640)
        XCTAssertEqual(savedSnapshot.healthReadStates?[HealthMetricID.activeEnergy.rawValue], .dataUnavailableOrReadScopeUnknown)
        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<UserProfile>()).first)
        let expectedFallback = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: [],
            workouts: [],
            userProfile: profile
        ).activeCaloriesKcal
        XCTAssertEqual(try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first).activeCaloriesKcal, expectedFallback)
    }
}

private enum TestSaveError: Error {
    case injected
}
