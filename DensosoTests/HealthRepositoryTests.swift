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
                DailyHealthSnapshotRecord.self, WeightRecord.self, ProfileRevisionRecord.self,
                HealthSyncOutboxEntry.self, HealthKitImportCursor.self, HealthKitSampleIndexRecord.self,
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

    func testProjectionUsesEffectiveProfileAndHistoricalWeightWithoutBorrowingFutureData() throws {
        let calendar = Calendar.current
        let targetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let targetDay = calendar.startOfDay(for: targetDate)
        let twoDaysLater = calendar.date(byAdding: .day, value: 2, to: targetDay)!
        let threeDaysLater = calendar.date(byAdding: .day, value: 3, to: targetDay)!
        let tenDaysLater = calendar.date(byAdding: .day, value: 10, to: targetDay)!
        let twentyDaysLater = calendar.date(byAdding: .day, value: 20, to: targetDay)!
        let birthDate = Date(timeIntervalSince1970: 315_532_800)
        context.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: calendar.date(byAdding: .day, value: -365, to: targetDay)!,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 70,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        context.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: tenDaysLater,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 85,
            activityLevel: "active",
            source: "userEdited"
        ))
        context.insert(WeightRecord(
            sourceActionKey: "projection-historical-weight",
            measuredAt: twoDaysLater,
            kilograms: 65
        ))
        context.insert(WeightRecord(
            sourceActionKey: "projection-future-weight",
            measuredAt: calendar.date(byAdding: .day, value: 50, to: targetDay)!,
            kilograms: 95
        ))

        let futureBodyMass = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000025")!,
            metric: .bodyMass,
            startDate: twentyDaysLater,
            endDate: twentyDaysLater,
            value: 120
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        for (day, activeEnergy, samples) in [
            (targetDay, 500.0, [HealthSampleSnapshot]()),
            (twentyDaysLater, 999.0, [futureBodyMass]),
        ] {
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                activeEnergyKcal: activeEnergy,
                healthKitSamples: samples,
                healthReadStates: [HealthMetricID.activeEnergy.rawValue: .available],
                algorithmVersion: "projector-boundary-fixture"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: Self.dayKey(day),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "projector-\(activeEnergy)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        try context.save()

        let repository = HealthRepository(modelContext: context)
        try repository.insert(WorkoutRecord(date: targetDay))
        let firstMetric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first {
            calendar.isDate($0.date, inSameDayAs: targetDay)
        })
        XCTAssertEqual(firstMetric.weightKg, 70)
        XCTAssertEqual(firstMetric.activeCaloriesKcal, 500)

        try repository.insert(WorkoutRecord(date: threeDaysLater))
        let laterMetric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first {
            calendar.isDate($0.date, inSameDayAs: threeDaysLater)
        })
        XCTAssertEqual(laterMetric.weightKg, 65)
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

        let priorDay = Calendar.current.date(byAdding: .day, value: -2, to: date)!
        let duplicateDay = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        let otherHealthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let olderCopy = WorkoutRecord(date: priorDay, type: "old-copy", notes: "preferred", healthKitUUID: healthKitUUID)
        olderCopy.createdAt = Date(timeIntervalSince1970: 1_699_900_000)
        let newerCopy = WorkoutRecord(date: duplicateDay, type: "duplicate-copy", notes: "discarded", healthKitUUID: healthKitUUID)
        newerCopy.createdAt = Date(timeIntervalSince1970: 1_699_950_000)
        let unrelatedDay = Calendar.current.date(byAdding: .day, value: 5, to: date)!
        let unrelatedDuplicateDay = Calendar.current.date(byAdding: .day, value: 6, to: date)!
        let unrelatedOlderCopy = WorkoutRecord(
            date: unrelatedDay,
            notes: "unrelated-preferred",
            healthKitUUID: otherHealthKitUUID
        )
        unrelatedOlderCopy.createdAt = Date(timeIntervalSince1970: 1_699_800_000)
        let unrelatedNewerCopy = WorkoutRecord(
            date: unrelatedDuplicateDay,
            notes: "unrelated-discarded",
            healthKitUUID: otherHealthKitUUID
        )
        unrelatedNewerCopy.createdAt = Date(timeIntervalSince1970: 1_699_850_000)
        let manualWorkout = WorkoutRecord(date: unrelatedDay, type: "manual")
        context.insert(newerCopy)
        context.insert(olderCopy)
        context.insert(unrelatedNewerCopy)
        context.insert(unrelatedOlderCopy)
        context.insert(manualWorkout)
        try context.save()

        try repository.applyImportedWorkouts([first, updated], deletedHealthKitUUIDs: [], nextAnchorData: Data([1]))

        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        let importedWorkouts = workouts.filter { $0.healthKitUUID == healthKitUUID }
        XCTAssertEqual(importedWorkouts.count, 1)
        XCTAssertEqual(importedWorkouts[0].notes, "preferred")
        XCTAssertEqual(importedWorkouts[0].date, date)
        XCTAssertEqual(importedWorkouts[0].logicalSessionID, logicalSessionID)
        XCTAssertEqual(importedWorkouts[0].estimatedCaloriesBurned, 275)
        XCTAssertEqual(importedWorkouts[0].energySource, WorkoutEnergySource.measured.rawValue)
        let unrelatedWorkouts = workouts.filter { $0.healthKitUUID == otherHealthKitUUID }
        XCTAssertEqual(unrelatedWorkouts.count, 1)
        XCTAssertEqual(unrelatedWorkouts.first?.notes, "unrelated-preferred")
        XCTAssertTrue(workouts.contains { $0.id == manualWorkout.id && $0.healthKitUUID == nil })
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([1]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 0)
        XCTAssertEqual(importedWorkouts.first?.routeStatus, "unavailable")
        let metricsByDay = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<DailyMetrics>()).map { ($0.date, $0.workoutCount) }
        )
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: priorDay)], 0)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: duplicateDay)], 0)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: date)], 1)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: unrelatedDay)], 2)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: unrelatedDuplicateDay)], 0)

        try repository.applyImportedWorkouts([], deletedHealthKitUUIDs: [healthKitUUID], nextAnchorData: Data([2]))

        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).filter {
            $0.healthKitUUID == healthKitUUID
        }.count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).filter {
            $0.healthKitUUID == otherHealthKitUUID
        }.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).contains {
            $0.id == manualWorkout.id && $0.healthKitUUID == nil
        })
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([2]))
        let metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) })?.workoutCount, 0)
    }

    func testImportedWorkoutAndAnchorRollbackTogetherWhenSaveFails() throws {
        let repository = HealthRepository(modelContext: context, willSave: { throw TestSaveError.injected })
        let snapshot = try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            logicalSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 250),
            origin: .watchHealthKit,
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: .complete
        )

        XCTAssertThrowsError(try repository.applyImportedWorkouts(
            [snapshot], deletedHealthKitUUIDs: [], nextAnchorData: Data([7])
        ))
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).isEmpty)
        XCTAssertNil(try repository.cursor(for: "workouts"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyMetrics>()).isEmpty)
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

        let day = Calendar.current.startOfDay(for: sample.startDate)
        XCTAssertThrowsError(try repository.applyImportedHealthSamples(
            page,
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: nil,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [sample], readState: .available)]
        ))
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
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: date),
                samples: [first],
                readState: .available
            )]
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [updated, updated], nextAnchorData: Data([2]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: date),
                samples: [updated],
                readState: .available
            )]
        )

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: stored.payloadData)
        XCTAssertNil(snapshot.healthKitSamples)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.sampleCount, 1)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 71)
        XCTAssertEqual(snapshot.weightKilograms, 71)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).count, 1)
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([2]))

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], deletedSampleIDs: [sampleID], nextAnchorData: Data([3]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: date),
                samples: [],
                readState: .available
            )]
        )
        let afterDeletion = try decoder.decode(DailyHealthSnapshot.self, from: XCTUnwrap(
            context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first
        ).payloadData)
        XCTAssertNil(afterDeletion.healthKitSamples)
        XCTAssertNil(afterDeletion.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertNil(afterDeletion.weightKilograms)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).isEmpty)
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([3]))

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([4]), readState: .dataUnavailableOrReadScopeUnknown),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: []
        )
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([4]))
        XCTAssertNotNil(try repository.cursor(for: "bodyMass")?.lastSuccessfulAt)

        try repository.resetHealthKitCursors()
        XCTAssertNil(try repository.cursor(for: "bodyMass")?.anchorData)
        XCTAssertNil(try repository.cursor(for: "bodyMass")?.lastSuccessfulAt)
    }

    func testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
        let sample = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: date,
            endDate: date,
            value: 69
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date,
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [sample], readState: .available)]
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(
                samples: [],
                deletedSampleIDs: [sampleID],
                nextAnchorData: Data([2]),
                readState: .available
            ),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date.addingTimeInterval(60),
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(
                dayStart: day,
                samples: [],
                readState: .dataUnavailableOrReadScopeUnknown
            )]
        )

        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 69)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertNil(snapshot.weightKilograms)
        XCTAssertNil(try context.fetch(FetchDescriptor<DailyMetrics>()).first?.weightKg)
        let pendingIndex = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).first)
        XCTAssertEqual(pendingIndex.sampleID, sampleID)
        XCTAssertTrue(pendingIndex.needsRequery)

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([3]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date.addingTimeInterval(120),
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [], readState: .available)]
        )
        let confirmedDeletion = try decoder.decode(
            DailyHealthSnapshot.self,
            from: XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first).payloadData
        )
        XCTAssertNil(confirmedDeletion.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertEqual(confirmedDeletion.healthReadStates?[HealthMetricID.bodyMass.rawValue], .available)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).isEmpty)
    }

    func testAnchoredAdditionStaysIndexedWhenFullDayReadIsUnknown() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000034")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
        let sample = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: date,
            endDate: date,
            value: 71
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date,
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(
                dayStart: day,
                samples: [],
                readState: .dataUnavailableOrReadScopeUnknown
            )]
        )

        let index = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).first)
        XCTAssertEqual(index.sampleID, sampleID)
        XCTAssertEqual(index.dayKey, Self.dayKey(day))
        XCTAssertTrue(index.needsRequery)
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: stored.payloadData)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertNil(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass))
    }

    func testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches() throws {
        let repository = HealthRepository(modelContext: context)
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        var expectedDays = Set<Date>()
        for offset in 0..<401 {
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            expectedDays.insert(day)
            context.insert(HealthKitSampleIndexRecord(
                sampleID: UUID(),
                stream: HealthMetricID.bodyMass.rawValue,
                dayKey: Self.dayKey(day),
                startDate: day,
                endDate: day,
                needsRequery: true
            ))
        }
        try context.save()

        let page = HealthSamplePage(samples: [], nextAnchorData: Data([1]), readState: .available)
        let affectedDays = try repository.affectedHealthSampleDays(
            for: page,
            stream: HealthMetricID.bodyMass.rawValue
        )

        XCTAssertEqual(affectedDays.count, 401)
        XCTAssertEqual(Set(affectedDays), expectedDays)
    }

    func testSleepDeletionTargetsOnlyWakeDaysIntersectingTheStoredInterval() throws {
        let repository = HealthRepository(modelContext: context)
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let wakeDay = calendar.date(byAdding: .day, value: 1, to: startDay)!
        let sampleStart = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: startDay)!
        let sampleEnd = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: wakeDay)!
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000035")!
        let sample = HealthSampleSnapshot(
            id: sampleID,
            metric: .sleepAnalysis,
            startDate: sampleStart,
            endDate: sampleEnd,
            categoryValue: "asleepCore",
            sourceBundleIdentifier: "com.example.health",
            deviceModel: "Watch6,1"
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.sleepAnalysis.rawValue,
            lastSuccessfulAt: sampleEnd,
            lookbackStart: startDay,
            replacements: [HealthSampleDaySnapshot(
                dayStart: wakeDay,
                samples: [sample],
                readState: .available
            )]
        )

        let deletionPage = HealthSamplePage(
            samples: [],
            deletedSampleIDs: [sampleID],
            nextAnchorData: Data([2]),
            readState: .available
        )
        XCTAssertEqual(
            try repository.affectedHealthSampleDays(for: deletionPage, stream: HealthMetricID.sleepAnalysis.rawValue),
            [wakeDay]
        )
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
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: firstDate,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: firstDate),
                samples: [first],
                readState: .available
            )]
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [moved], nextAnchorData: Data([2]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: firstDate,
            replacements: [
                HealthSampleDaySnapshot(
                    dayStart: Calendar.current.startOfDay(for: firstDate),
                    samples: [],
                    readState: .available
                ),
                HealthSampleDaySnapshot(
                    dayStart: Calendar.current.startOfDay(for: movedDate),
                    samples: [moved],
                    readState: .available
                ),
            ]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        let originalDay = try XCTUnwrap(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: firstDate) }))
        let movedDay = try XCTUnwrap(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: movedDate) }))
        XCTAssertNil(originalDay.healthKitSamples)
        XCTAssertNil(originalDay.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertNil(originalDay.weightKilograms)
        XCTAssertNil(movedDay.healthKitSamples)
        XCTAssertEqual(movedDay.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestSampleID, sampleID)
        XCTAssertEqual(movedDay.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 72)
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
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metric.activeCaloriesKcal, 0)
        XCTAssertEqual(metric.energyQuality, "unavailable")
    }

    func testHealthSnapshotUpsertUpdatesOnlyTheMatchingDayKey() throws {
        let targetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let targetDay = Calendar.current.startOfDay(for: targetDate)
        let neighboringDay = Calendar.current.date(byAdding: .day, value: 1, to: targetDay)!
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        for (day, energy) in [(targetDay, 100.0), (neighboringDay, 200.0)] {
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: Calendar.current.timeZone.identifier,
                activeEnergyKcal: energy,
                healthReadStates: [HealthMetricID.activeEnergy.rawValue: .available],
                algorithmVersion: "lookup-fixture"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: Self.dayKey(day),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "lookup-\(energy)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        try context.save()

        try HealthRepository(modelContext: context).applyHealthAggregates(
            [HealthAggregateBucket(
                startDate: targetDay,
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: targetDay)!,
                value: 640
            )],
            metric: .activeEnergy,
            stream: "activeEnergy",
            lookbackStart: targetDay
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: targetDay) })?.activeEnergyKcal, 640)
        XCTAssertEqual(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: neighboringDay) })?.activeEnergyKcal, 200)
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private enum TestSaveError: Error {
    case injected
}
