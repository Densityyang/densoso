import Foundation
import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class HealthKitSyncCoordinatorTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self,
                DailyHealthSnapshotRecord.self, DailyBriefRecord.self, WeeklyBriefRecord.self, GoalProfileRecord.self,
                ProfileRevisionRecord.self,
                WeightRecord.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self, HealthKitSampleIndexRecord.self,
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

    func testObserverCompletionRunsAfterAnchoredWorkoutIsCommitted() async throws {
        let date = Date()
        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000055")!
        let snapshot = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            startedAt: date,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 250),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [snapshot], deletedObjectIDs: [], nextAnchorData: Data([1]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let repository = HealthRepository(modelContext: context)
        let intelligence = HealthIntelligenceService(modelContainer: container)
        var observerRefreshCount = 0
        var refreshSawCommittedWorkout = false
        var refreshedBriefDay: Date?
        coordinator.onObserverSyncCompleted = { _, _ in
            observerRefreshCount += 1
            refreshSawCommittedWorkout = ((try? self.context.fetch(FetchDescriptor<WorkoutRecord>())) ?? [])
                .contains(where: { $0.healthKitUUID == workoutID })
            _ = try? await intelligence.refresh(asOf: date)
            refreshedBriefDay = intelligence.dailyBrief?.dayStart
        }
        try await coordinator.startBackgroundObservers(using: repository)
        let previousCompletions = await fake.completedObserverCount()

        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: previousCompletions)

        let completedCount = await fake.completedObserverCount()
        XCTAssertEqual(completedCount, previousCompletions + 1)
        let imported = try context.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.healthKitUUID, workoutID)
        XCTAssertEqual(observerRefreshCount, 1)
        XCTAssertTrue(refreshSawCommittedWorkout)
        XCTAssertEqual(try XCTUnwrap(refreshedBriefDay), Calendar.current.startOfDay(for: date))
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == "workouts" })?.anchorData, Data([1]))
    }

    func testEffortSampleIsReassociatedWhenWorkoutArrivesLater() async throws {
        // Keep the sample and workout on one local day even when CI runs near
        // midnight; the association is projected into the workout's day.
        let now = try XCTUnwrap(Calendar.current.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: Date()
        ))
        let day = Calendar.current.startOfDay(for: now)
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000081")!,
            metric: .workoutEffort,
            startDate: now.addingTimeInterval(-45 * 60),
            endDate: now.addingTimeInterval(-15 * 60),
            value: 8
        )
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let repository = HealthRepository(modelContext: context)
        try await coordinator.startBackgroundObservers(using: repository)

        // The effort stream is observed before HealthKit has delivered the
        // corresponding workout record. Its sample is retained, but cannot yet
        // be associated with a WorkoutRecord.
        await fake.setSampleResponses([
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            HealthSamplePage(samples: [sample], nextAnchorData: Data([2]), readState: .available),
        ], for: .workoutEffort)
        await fake.triggerObserver(.workoutEffort)
        await fake.waitForObserverCompletion(after: 0)
        let snapshotBeforeWorkout = try healthSnapshot(on: day)
        XCTAssertTrue(snapshotBeforeWorkout.healthKitSampleSummary?.workoutEffort.isEmpty ?? true)

        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000082")!
        let workout = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            startedAt: now.addingTimeInterval(-60 * 60),
            duration: 45 * 60,
            activityType: "running",
            energyInput: .init(),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([1]))
        ])
        // A first-time workout rebuild invalidates its dependent effort cache.
        // The follow-up effort scan reads the sample, then requeries that day
        // against the now-committed WorkoutRecord.
        await fake.setSampleResponses([
            HealthSamplePage(samples: [sample], nextAnchorData: Data([2]), readState: .available),
            HealthSamplePage(samples: [sample], nextAnchorData: Data([3]), readState: .available),
        ], for: .workoutEffort)
        let priorCompletions = await fake.completedObserverCount()
        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: priorCompletions)

        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workoutID
        })
        let reconciled = try healthSnapshot(on: day)
        XCTAssertEqual(reconciled.healthKitSampleSummary?.effortScore(for: imported.id), 8)
        XCTAssertTrue(try repository.pendingHealthSampleDays(stream: HealthMetricID.workoutEffort.rawValue).isEmpty)

        let retryCompletions = await fake.completedObserverCount()
        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: retryCompletions)
        let retried = try healthSnapshot(on: day)
        XCTAssertEqual(retried.healthKitSampleSummary?.workoutEffort, reconciled.healthKitSampleSummary?.workoutEffort)
    }

    func testWorkoutUpdateRebuildsEffortAssociationForAffectedDay() async throws {
        let now = try XCTUnwrap(Calendar.current.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: Date()
        ))
        let day = Calendar.current.startOfDay(for: now)
        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000083")!
        let sample = effortSample(id: "00000000-0000-0000-0000-000000000084", at: now)
        let original = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            startedAt: now.addingTimeInterval(-60 * 60),
            duration: 45 * 60,
            activityType: "running",
            energyInput: .init(),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let repository = HealthRepository(modelContext: context)
        let originalRecordID = try await seedWorkoutAndEffort(original, sample: sample, day: day, repository: repository)
        XCTAssertEqual(try healthSnapshot(on: day).healthKitSampleSummary?.effortScore(for: originalRecordID), 7)

        let updated = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            startedAt: now.addingTimeInterval(-5 * 60),
            duration: 15 * 60,
            activityType: "running",
            energyInput: .init(),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [updated], deletedObjectIDs: [], nextAnchorData: Data([2]))
        ])
        await fake.setSampleResponses([
            HealthSamplePage(samples: [], nextAnchorData: Data([2]), readState: .available),
            HealthSamplePage(samples: [sample], nextAnchorData: Data([3]), readState: .available),
        ], for: .workoutEffort)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        try await coordinator.startBackgroundObservers(using: repository)

        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: 0)

        let record = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workoutID
        })
        XCTAssertEqual(record.id, originalRecordID)
        XCTAssertEqual(record.date, updated.startedAt)
        XCTAssertNil(try healthSnapshot(on: day).healthKitSampleSummary?.effortScore(for: record.id))
        XCTAssertTrue(try repository.pendingHealthSampleDays(stream: HealthMetricID.workoutEffort.rawValue).isEmpty)
    }

    func testWorkoutDeletionRemovesOrphanedEffortAssociation() async throws {
        let now = try XCTUnwrap(Calendar.current.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: Date()
        ))
        let day = Calendar.current.startOfDay(for: now)
        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000085")!
        let sample = effortSample(id: "00000000-0000-0000-0000-000000000086", at: now)
        let workout = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            startedAt: now.addingTimeInterval(-60 * 60),
            duration: 45 * 60,
            activityType: "running",
            energyInput: .init(),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let repository = HealthRepository(modelContext: context)
        let workoutRecordID = try await seedWorkoutAndEffort(workout, sample: sample, day: day, repository: repository)
        XCTAssertEqual(try healthSnapshot(on: day).healthKitSampleSummary?.effortScore(for: workoutRecordID), 7)

        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [], deletedObjectIDs: [workoutID], nextAnchorData: Data([2]))
        ])
        await fake.setSampleResponses([
            HealthSamplePage(samples: [], nextAnchorData: Data([2]), readState: .available),
            HealthSamplePage(samples: [sample], nextAnchorData: Data([3]), readState: .available),
        ], for: .workoutEffort)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        try await coordinator.startBackgroundObservers(using: repository)

        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: 0)

        XCTAssertFalse(try context.fetch(FetchDescriptor<WorkoutRecord>()).contains { $0.healthKitUUID == workoutID })
        XCTAssertTrue(try healthSnapshot(on: day).healthKitSampleSummary?.workoutEffort.isEmpty ?? false)
        XCTAssertTrue(try repository.pendingHealthSampleDays(stream: HealthMetricID.workoutEffort.rawValue).isEmpty)
    }

    func testMeasuredDailyActivityAggregateFeedsProjectionWithoutWorkoutEnergy() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: now)
        let fake = FakeHealthStoreClient()
        await fake.setAggregateResponse([
            HealthAggregateBucket(startDate: day, endDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!, value: 640)
        ], for: .activeEnergy)
        await fake.setWorkoutResponses([
            HealthChangePage(added: [try WorkoutSnapshot(
                healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000056")!,
                startedAt: now,
                duration: 3_600,
                activityType: "running",
                energyInput: .init(measuredKilocalories: 420),
                origin: .externalHealthKit,
                dataQuality: .complete
            )], deletedObjectIDs: [], nextAnchorData: Data([2]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let report = try await coordinator.syncAvailableData(using: HealthRepository(modelContext: context), now: now)

        let metrics = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first {
            Calendar.current.startOfDay(for: $0.date) == day
        })
        XCTAssertEqual(metrics.activeCaloriesKcal, 0)
        XCTAssertEqual(try XCTUnwrap(metrics.activeEnergyKcal), 640)
        XCTAssertEqual(metrics.workoutCount, 1)
        XCTAssertEqual(metrics.totalExpenditureKcal, 0)
        XCTAssertEqual(metrics.energyQuality, "unavailable")
        XCTAssertTrue(report.failedStreams.isEmpty)
    }

    func testInitialHealthKitBackfillUsesTheSame42DayWindowForEveryStreamType() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let expectedStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        XCTAssertEqual(HealthDataWindowPolicy.analysisStart(through: now, calendar: calendar), expectedStart)
        XCTAssertEqual(
            HealthDataWindowPolicy.days(
                from: expectedStart,
                through: calendar.startOfDay(for: now),
                calendar: calendar
            ).count,
            42
        )
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.failedStreams.isEmpty)
        let aggregateRequests = await fake.aggregateRequests(for: .activeEnergy)
        let sampleRequests = await fake.sampleRequests(for: .bodyMass)
        let workoutStarts = await fake.workoutRequestStartDates()
        XCTAssertEqual(try XCTUnwrap(aggregateRequests.first).startDate, expectedStart)
        XCTAssertEqual(try XCTUnwrap(sampleRequests.first).startDate, expectedStart)
        XCTAssertEqual(try XCTUnwrap(workoutStarts.first), expectedStart)
    }

    func testPreparedRebaselineFromAnotherTimeZoneIsRejectedBeforeSync() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar.autoupdatingCurrent
        let start = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let preparation = HealthKitSnapshotRebuildPreparation(
            windowStart: start,
            through: now,
            timeZoneIdentifier: "\(calendar.timeZone.identifier).previous"
        )
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        do {
            _ = try await coordinator.syncAvailableData(
                using: HealthRepository(modelContext: context),
                now: now,
                forceRebaseline: true,
                preparedSnapshotRebuild: preparation
            )
            XCTFail("A preparation from an old time zone must be retried before syncing")
        } catch {
            XCTAssertEqual(error as? HealthStoreClientError, .invalidAnchor)
        }

        let aggregateRequests = await fake.aggregateRequests(for: .stepCount)
        let sampleRequests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertTrue(aggregateRequests.isEmpty)
        XCTAssertTrue(sampleRequests.isEmpty)
    }

    func testBackgroundAggregateSyncUsesRollingWindowWithoutPurgingBriefCache() async throws {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let oldDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: today))
        let missingRecentDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let recentDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let nextOldDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: oldDay))
        let nextMissingRecentDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: missingRecentDay))
        let nextRecentDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: recentDay))
        let lastSync = now.addingTimeInterval(-60 * 60)
        let repository = HealthRepository(modelContext: context)

        try await repository.applyHealthAggregates(
            [
                HealthAggregateBucket(startDate: oldDay, endDate: nextOldDay, value: 300),
                HealthAggregateBucket(startDate: missingRecentDay, endDate: nextMissingRecentDay, value: 400),
                HealthAggregateBucket(startDate: recentDay, endDate: nextRecentDay, value: 500),
            ],
            metric: .activeEnergy,
            stream: HealthMetricID.activeEnergy.rawValue,
            lookbackStart: targetStart,
            through: now,
            lastSuccessfulAt: lastSync
        )
        for metric in HealthKitSyncCoordinator.aggregateStreams where metric != .activeEnergy {
            try await repository.applyHealthAggregates(
                [HealthAggregateBucket(startDate: recentDay, endDate: nextRecentDay, value: 10)],
                metric: metric,
                stream: metric.rawValue,
                lookbackStart: targetStart,
                through: now,
                lastSuccessfulAt: lastSync
            )
        }
        for metric in HealthKitSyncCoordinator.sampleStreams {
            let cursorStart: Date
            if metric == .sleepAnalysis {
                let previousDay = calendar.date(byAdding: .day, value: -1, to: targetStart) ?? targetStart
                cursorStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay) ?? previousDay
            } else {
                cursorStart = targetStart
            }
            try await repository.applyImportedHealthSamples(
                HealthSamplePage(samples: [], nextAnchorData: Data([1]), readState: .available),
                stream: metric.rawValue,
                lastSuccessfulAt: lastSync,
                lookbackStart: cursorStart,
                replacements: []
            )
        }
        try await repository.applyImportedWorkouts(
            [],
            deletedHealthKitUUIDs: [],
            nextAnchorData: Data([1]),
            lookbackStart: targetStart
        )
        context.insert(DailyBriefRecord(
            cacheKey: "daily:incremental-aggregate-fixture",
            dayKey: Self.dayKey(today, calendar: calendar),
            snapshotHash: "still-valid-until-projection-refresh",
            algorithmVersion: "test-v1",
            payloadData: Data([1])
        ))
        try context.save()

        let fake = FakeHealthStoreClient()
        await fake.setAggregateResponse([
            HealthAggregateBucket(startDate: recentDay, endDate: nextRecentDay, value: 650)
        ], for: .activeEnergy)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let result = try await coordinator.syncAvailableData(
            using: repository,
            now: now,
            forceRebaseline: false,
            aggregateIncrementalLookbackDays: 3
        )

        XCTAssertTrue(result.failedStreams.isEmpty)
        let activeEnergyRequests = await fake.aggregateRequests(for: .activeEnergy)
        XCTAssertGreaterThan(try XCTUnwrap(activeEnergyRequests.first).startDate, targetStart)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
        let decoded = try snapshots.map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        XCTAssertEqual(decoded.first(where: { calendar.isDate($0.dayStart, inSameDayAs: oldDay) })?.activeEnergyKcal, 300)
        XCTAssertEqual(decoded.first(where: { calendar.isDate($0.dayStart, inSameDayAs: recentDay) })?.activeEnergyKcal, 650)
        let missingRecent = try XCTUnwrap(decoded.first(where: {
            calendar.isDate($0.dayStart, inSameDayAs: missingRecentDay)
        }))
        XCTAssertNil(missingRecent.activeEnergyKcal)
        XCTAssertEqual(
            missingRecent.healthReadStates?[HealthMetricID.activeEnergy.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let authorizationStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let fake = FakeHealthStoreClient()
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .activeEnergy)
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .bodyMass)
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .workout)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.failedStreams.isEmpty)
        let aggregateRequests = await fake.aggregateRequests(for: .activeEnergy)
        let sampleRequests = await fake.sampleRequests(for: .bodyMass)
        let workoutStarts = await fake.workoutRequestStartDates()
        XCTAssertEqual(try XCTUnwrap(aggregateRequests.first).startDate, authorizationStart)
        XCTAssertEqual(try XCTUnwrap(sampleRequests.first).startDate, authorizationStart)
        XCTAssertEqual(try XCTUnwrap(workoutStarts.first), authorizationStart)

        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.analysisStart(through: today, calendar: calendar)
        )
        let unknownDay = targetStart
        let dayKey = Self.dayKey(unknownDay, calendar: calendar)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.activeEnergy.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.workout.rawValue], .dataUnavailableOrReadScopeUnknown)
    }

    func testLimitedHistoryRetainsSamplesAndWorkoutsEndingAfterAuthorizationBoundary() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let boundaryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let authorizationStart = try XCTUnwrap(
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: boundaryDay)
        )
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000781")!
        let crossingSleepSample = HealthSampleSnapshot(
            id: sampleID,
            metric: .sleepAnalysis,
            startDate: authorizationStart.addingTimeInterval(-1_800),
            endDate: authorizationStart.addingTimeInterval(1_800),
            categoryValue: "asleepCore"
        )
        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000782")!
        let crossingWorkout = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            startedAt: authorizationStart.addingTimeInterval(-900),
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 120),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let fake = FakeHealthStoreClient()
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .sleepAnalysis)
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .workout)
        await fake.setSampleResponses([
            HealthSamplePage(
                samples: [crossingSleepSample],
                nextAnchorData: Data([78]),
                readState: .available
            ),
        ], for: .sleepAnalysis)
        await fake.setWorkoutResponses([
            HealthChangePage(added: [crossingWorkout], deletedObjectIDs: [], nextAnchorData: Data([79]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.sleepAnalysis))
        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNil(result.failedStreams[.sleepAnalysis])
        XCTAssertNil(result.failedStreams[.workout])
        let indexedSample = try XCTUnwrap(
            context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
                .first(where: { $0.sampleID == sampleID })
        )
        XCTAssertEqual(indexedSample.endDate, crossingSleepSample.endDate)
        let importedWorkout = try XCTUnwrap(
            context.fetch(FetchDescriptor<WorkoutRecord>())
                .first(where: { $0.healthKitUUID == workoutID })
        )
        XCTAssertEqual(importedWorkout.date, crossingWorkout.startedAt)
        let sampleRequests = await fake.sampleRequests(for: .sleepAnalysis)
        XCTAssertEqual(try XCTUnwrap(sampleRequests.first).startDate, authorizationStart)
        let workoutStarts = await fake.workoutRequestStartDates()
        XCTAssertEqual(try XCTUnwrap(workoutStarts.first), authorizationStart)
    }

    func testWorkoutStartingAtNoonCanImportWhileBoundaryDayRemainsIncomplete() async throws {
        try await assertIntradayAuthorizationWorkoutRemainsUnknown(
            authorizationHour: 12,
            workoutHour: 13,
            workoutID: UUID(uuidString: "00000000-0000-0000-0000-000000000783")!,
            anchor: Data([80])
        )
    }

    func testWorkoutStartingAtOnePMCanImportWhileBoundaryDayRemainsIncomplete() async throws {
        try await assertIntradayAuthorizationWorkoutRemainsUnknown(
            authorizationHour: 13,
            workoutHour: 13,
            workoutID: UUID(uuidString: "00000000-0000-0000-0000-000000000784")!,
            anchor: Data([81])
        )
    }

    private func assertIntradayAuthorizationWorkoutRemainsUnknown(
        authorizationHour: Int,
        workoutHour: Int,
        workoutID: UUID,
        anchor: Data
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let boundaryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let authorizationStart = try XCTUnwrap(calendar.date(
            bySettingHour: authorizationHour,
            minute: 0,
            second: 0,
            of: boundaryDay
        ))
        let workoutStart = try XCTUnwrap(calendar.date(
            bySettingHour: workoutHour,
            minute: 0,
            second: 0,
            of: boundaryDay
        ))
        let workoutEnd = try XCTUnwrap(calendar.date(
            bySettingHour: 13,
            minute: 30,
            second: 0,
            of: boundaryDay
        ))
        let workout = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            startedAt: workoutStart,
            duration: workoutEnd.timeIntervalSince(workoutStart),
            activityType: "running",
            energyInput: .init(measuredKilocalories: 120),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let fake = FakeHealthStoreClient()
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .workout)
        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: anchor)
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNil(result.failedStreams[.workout])
        let imported = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>())
            .first { $0.healthKitUUID == workoutID })
        XCTAssertEqual(imported.date, workoutStart)
        XCTAssertEqual(imported.durationMinutes, Int((workoutEnd.timeIntervalSince(workoutStart) / 60).rounded()))
        let requests = await fake.workoutRequestStartDates()
        XCTAssertEqual(try XCTUnwrap(requests.first), authorizationStart)

        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first { $0.dayKey == Self.dayKey(boundaryDay, calendar: calendar) })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testUnavailableAuthorizationBoundaryRebuildsWindowAndKeepsEmptyDaysUnknown() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let sampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: today))
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000739")!,
            metric: .bodyMass,
            startDate: sampleDay.addingTimeInterval(3_600),
            endDate: sampleDay.addingTimeInterval(3_600),
            value: 123.456789
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([7]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now,
            lookbackStart: calendar.date(byAdding: .day, value: -41, to: today),
            replacements: [HealthSampleDaySnapshot(dayStart: sampleDay, samples: [sample], readState: .available)]
        )
        let fake = FakeHealthStoreClient()
        await fake.failAuthorizationBoundaryLookup(for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let readModel = HealthIntelligenceReadModel(calendar: calendar)
        let staleContext = try XCTUnwrap(readModel.healthContextSummary(asOf: now, in: context))
        let encoder = JSONEncoder()
        let staleContextJSON = try XCTUnwrap(String(data: encoder.encode(staleContext), encoding: .utf8))
        XCTAssertTrue(staleContextJSON.contains("123.456789"))

        let preparation = try await coordinator.prepareForegroundSnapshotRebuild(using: repository, now: now)
        let rebuiltContext = try XCTUnwrap(readModel.healthContextSummary(asOf: now, in: context))
        let rebuiltContextJSON = try XCTUnwrap(String(data: encoder.encode(rebuiltContext), encoding: .utf8))
        XCTAssertFalse(rebuiltContextJSON.contains("123.456789"))

        let result = try await coordinator.syncAvailableData(
            using: repository,
            now: now,
            forceRebaseline: true,
            preparedSnapshotRebuild: preparation
        )

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        XCTAssertNil(result.failedStreams[.bodyMass])
        let cursor = try XCTUnwrap(repository.cursor(for: HealthMetricID.bodyMass.rawValue))
        XCTAssertEqual(cursor.anchorData, Data([0]))
        XCTAssertEqual(
            cursor.lookbackStart,
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertNil(requests.first?.anchorData)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).count, 0)
        let dayKey = Self.dayKey(sampleDay, calendar: calendar)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        let days = try HealthIntelligenceReadModel(calendar: calendar).loadDays(through: now, in: context)
        let projectedDay = try XCTUnwrap(days.first(where: { calendar.startOfDay(for: $0.dayStart) == sampleDay }))
        XCTAssertTrue(projectedDay.weightSamplesKilograms.isEmpty)
    }

    func testWorkoutWithUnavailableAuthorizationBoundaryRemainsImportedButDayCoverageUnknown() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: now)))
        let workoutStart = day.addingTimeInterval(13 * 60 * 60)
        let workout = try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000785")!,
            startedAt: workoutStart,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 120),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let fake = FakeHealthStoreClient()
        await fake.failAuthorizationBoundaryLookup(for: .workout)
        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([82]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNotNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workout.healthKitUUID
        })
        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first { $0.dayKey == Self.dayKey(day, calendar: calendar) })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testWorkoutCoverageRemainsUnknownWhenALaterPageFails() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: calendar.startOfDay(for: now)))
        let workout = try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000786")!,
            startedAt: day.addingTimeInterval(13 * 60 * 60),
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 120),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([83]), hasMore: true)
        ])
        await fake.failWorkoutChanges(afterSuccessfulPageCount: 1)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let repository = HealthRepository(modelContext: context)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertFalse(result.completedStreams.contains(.workout))
        XCTAssertNotNil(result.failedStreams[.workout])
        XCTAssertNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workout.healthKitUUID
        }, "No page rows commit until the terminal page and final anchor are validated")
        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first { $0.dayKey == Self.dayKey(day, calendar: calendar) })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        let noRecordDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        XCTAssertEqual(
            try healthSnapshot(on: noRecordDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown,
            "A partial paginated result cannot establish rest-day coverage"
        )
        XCTAssertNil(try repository.cursor(for: "workouts")?.anchorData)
    }

    func testImportedWorkoutAndAnchorAndReadStateCommitAtomically() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-3 * 86_400))
        let firstWorkout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000787",
            startedAt: day.addingTimeInterval(10 * 60 * 60)
        )
        let secondWorkout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000788",
            startedAt: day.addingTimeInterval(15 * 60 * 60)
        )
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [firstWorkout], deletedObjectIDs: [], nextAnchorData: Data([87]), hasMore: true),
            HealthChangePage(added: [secondWorkout], deletedObjectIDs: [], nextAnchorData: Data([88])),
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertEqual(result.readRecordCount, 2)
        let imported = try context.fetch(FetchDescriptor<WorkoutRecord>())
            .compactMap(\.healthKitUUID)
            .sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(imported, [firstWorkout.healthKitUUID, secondWorkout.healthKitUUID].sorted {
            $0.uuidString < $1.uuidString
        })
        let cursor = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == "workouts" }))
        XCTAssertEqual(cursor.anchorData, Data([88]))
        let snapshot = try healthSnapshot(on: day)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.workout.rawValue], .available)
    }

    func testWorkoutSaveFailureRollsBackThenRetriesAfterFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: Calendar.current)
        )
        let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        let workout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000789",
            startedAt: day.addingTimeInterval(11 * 60 * 60)
        )
        try seedAnchoredCursors(targetStart: targetStart, now: now)
        let originalAnchor = Data([89])
        let workoutCursor = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == "workouts" }))
        workoutCursor.anchorData = originalAnchor
        try context.save()

        var failNextSave = true
        let repository = HealthRepository(modelContext: context, willSave: {
            if failNextSave {
                failNextSave = false
                throw CoordinatorInjectedSaveFailure.failed
            }
        })
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([90]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let failed = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertNotNil(failed.failedStreams[.workout])
        XCTAssertNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workout.healthKitUUID
        })
        XCTAssertNil(try repository.cursor(for: "workouts")?.anchorData)
        XCTAssertEqual(
            try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )

        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([90]))
        ])
        let retried = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(retried.completedStreams.contains(.workout))
        XCTAssertNotNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workout.healthKitUUID
        })
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([90]))
        let anchors = await fake.workoutRequestAnchors()
        XCTAssertEqual(anchors.first ?? nil, originalAnchor)
        XCTAssertNil(anchors.last ?? nil)
        XCTAssertEqual(try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue], .available)
    }

    func testDeletedWorkoutDoesNotIncorrectlyMarkUnknownDayAvailable() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let day = calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400))
        let healthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000790")!
        context.insert(WorkoutRecord(
            date: day.addingTimeInterval(9 * 60 * 60),
            type: "running",
            durationMinutes: 30,
            estimatedCaloriesBurned: 140,
            intensity: "moderate",
            healthKitUUID: healthKitUUID,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue,
            energySource: WorkoutEnergySource.measured.rawValue
        ))
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: Data([91]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try insertHealthSnapshot(
            on: day,
            readStates: [HealthMetricID.workout.rawValue: .dataUnavailableOrReadScopeUnknown]
        )
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [], deletedObjectIDs: [healthKitUUID], nextAnchorData: Data([92]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first { $0.healthKitUUID == healthKitUUID })
        XCTAssertEqual(
            try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testEmptyFullWorkoutBackfillRemainsUnknownWithoutScopeEvidence() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let closedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: today))
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNil(result.failedStreams[.workout])
        XCTAssertEqual(
            try healthSnapshot(on: closedDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown,
            "A successful but empty full query cannot distinguish no workouts from an unreadable scope"
        )
        XCTAssertEqual(
            try healthSnapshot(on: today).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testFullWorkoutBackfillVerifiesAuthorizedCoverageThroughAsOfDayAfterEvidence() async throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024,
            month: 6,
            day: 20,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let boundaryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -8, to: today))
        let authorizationStart = try XCTUnwrap(calendar.date(
            bySettingHour: 12,
            minute: 0,
            second: 0,
            of: boundaryDay
        ))
        let boundaryDayAfter = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: boundaryDay))
        let emptyAuthorizedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: today))
        let evidenceDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let beforeBoundaryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: boundaryDay))
        let witness = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-0000000007A1",
            startedAt: evidenceDay.addingTimeInterval(14 * 60 * 60)
        )
        let fake = FakeHealthStoreClient()
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .workout)
        await fake.setWorkoutResponses([
            HealthChangePage(
                added: [witness],
                deletedObjectIDs: [],
                nextAnchorData: Data([0xA1]),
                hasMore: true
            ),
            HealthChangePage(added: [], deletedObjectIDs: [], nextAnchorData: Data([0xA2])),
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNotNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == witness.healthKitUUID
        }, "Scope evidence must be persisted in the same commit as coverage")
        XCTAssertEqual(
            try healthSnapshot(on: emptyAuthorizedDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "A closed no-record day is verified after the same full query returns authorized scope evidence"
        )
        XCTAssertEqual(
            try healthSnapshot(on: boundaryDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown,
            "An intraday authorization boundary does not certify its partial day"
        )
        XCTAssertEqual(
            try healthSnapshot(on: boundaryDayAfter).healthReadStates?[HealthMetricID.workout.rawValue],
            .available
        )
        XCTAssertEqual(
            try healthSnapshot(on: beforeBoundaryDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        XCTAssertEqual(
            try healthSnapshot(on: today).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "The current day is readable through the query time, without claiming the remaining day is complete"
        )
    }

    func testVerifiedWorkoutCoverageFromSyncReachesTrainingReadModelWindow() async throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024,
            month: 6,
            day: 20,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let witnessDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let witness = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-0000000007A4",
            startedAt: witnessDay.addingTimeInterval(10 * 60 * 60)
        )
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [witness], deletedObjectIDs: [], nextAnchorData: Data([0xAB]))
        ])
        let result = try await HealthKitSyncCoordinator(healthStore: fake, observer: fake)
            .syncAvailableData(using: HealthRepository(modelContext: context), now: now)

        XCTAssertTrue(result.completedStreams.contains(.workout))
        let readModel = HealthIntelligenceReadModel(calendar: calendar)
        let days = try readModel.loadDays(through: now, in: context)
        let trainingWindowStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -34, to: today))
        let trainingWindow = days.filter {
            let day = calendar.startOfDay(for: $0.dayStart)
            return day >= trainingWindowStart && day <= today
        }

        XCTAssertEqual(trainingWindow.count, 35)
        XCTAssertTrue(trainingWindow.allSatisfy {
            $0.healthReadStates?[HealthMetricID.workout.rawValue] == .available
        }, "The complete training-load history and as-of day must reach ReadModel with coverage")
        let witnessReadModelDay = try XCTUnwrap(trainingWindow.first(where: {
            calendar.isDate($0.dayStart, inSameDayAs: witnessDay)
        }))
        XCTAssertEqual(
            witnessReadModelDay.workouts.count,
            1
        )
        let currentReadModelDay = try XCTUnwrap(trainingWindow.first(where: {
            calendar.isDate($0.dayStart, inSameDayAs: today)
        }))
        XCTAssertEqual(
            currentReadModelDay.healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "The as-of day is available through sync time while later hours remain unobserved"
        )
    }

    func testFullWorkoutSyncProducesMatureTrainingLoadAndRecoveryEvidence() async throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024,
            month: 7,
            day: 1,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let priorOffsets = Array(-14 ... -8)
        let workouts = try priorOffsets.enumerated().map { index, offset in
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            let start = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day))
            let workoutID = String(format: "00000000-0000-0000-0000-%012X", index + 0xB00)
            return try makeWorkoutSnapshot(id: workoutID, startedAt: start)
        }
        let effortSamples = workouts.enumerated().map { index, workout in
            HealthSampleSnapshot(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", index + 0xC00))!,
                metric: .workoutEffort,
                startDate: workout.startedAt.addingTimeInterval(5 * 60),
                endDate: workout.startedAt.addingTimeInterval(15 * 60),
                value: 7.5
            )
        }
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: workouts, deletedObjectIDs: [], nextAnchorData: Data([0xB0]))
        ])
        let effortDayRequeries = effortSamples.enumerated().map { index, sample in
            HealthSamplePage(
                samples: [sample],
                nextAnchorData: Data([UInt8(0xC0 + index)]),
                readState: .available
            )
        }
        await fake.setSampleResponses([
            HealthSamplePage(
                samples: effortSamples,
                nextAnchorData: Data([0xB1]),
                readState: .available
            ),
        ] + effortDayRequeries, for: .workoutEffort)
        let repository = HealthRepository(modelContext: context)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let syncResult = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(syncResult.completedStreams.contains(.workout))
        XCTAssertNil(syncResult.failedStreams[.workout])
        XCTAssertNil(syncResult.failedStreams[.workoutEffort])
        let readModelDays = try HealthIntelligenceReadModel(calendar: calendar).loadDays(
            through: now,
            in: context
        )
        let result = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).makeDailyBrief(days: readModelDays))
        let load = result.dailyBrief.trainingLoad
        XCTAssertEqual(load.dataCoverage, .complete)
        XCTAssertEqual(load.readiness, .mature)
        XCTAssertNotNil(load.ratio)
        let synchronizedTrainingWorkouts = readModelDays.flatMap(\.workouts).filter {
            priorOffsets.contains(calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: $0.startedAt)).day ?? 0)
        }
        XCTAssertEqual(synchronizedTrainingWorkouts.count, 7)
        XCTAssertTrue(synchronizedTrainingWorkouts.allSatisfy { $0.effortScore == 7.5 })
        XCTAssertTrue(
            result.dailyBrief.healthState?.recovery.evidence.contains {
                $0.key == "trainingLoad.ratio" && $0.source == "trainingLoad"
            } == true,
            "Recovery must consume the mature load derived from synchronized HealthKit workouts and effort samples"
        )
        XCTAssertEqual(
            result.dailyBrief.healthState?.recovery.status,
            .insufficientEvidence,
            "Training load is available, while missing sleep and vital evidence still keeps recovery fail-closed"
        )
    }

    func testIncrementalWorkoutQueryPreservesVerifiedRestAfterEmptyPageAndDeletion() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let witnessDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: today))
        let verifiedRestDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: today))
        let witness = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-0000000007A2",
            startedAt: witnessDay.addingTimeInterval(10 * 60 * 60)
        )
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [witness], deletedObjectIDs: [], nextAnchorData: Data([0xA3]))
        ])
        let repository = HealthRepository(modelContext: context)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let fullResult = try await coordinator.syncAvailableData(using: repository, now: now)
        XCTAssertTrue(fullResult.completedStreams.contains(.workout))
        XCTAssertEqual(
            try healthSnapshot(on: verifiedRestDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .available
        )
        XCTAssertEqual(
            try healthSnapshot(on: today).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "A witnessed full query covers the current day only as of sync time"
        )

        await fake.setWorkoutResponses([
            HealthChangePage(added: [], deletedObjectIDs: [], nextAnchorData: Data([0xA4]))
        ])
        let nextDayNow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
        let emptyIncrementalResult = try await coordinator.syncAvailableData(using: repository, now: nextDayNow)
        XCTAssertTrue(emptyIncrementalResult.completedStreams.contains(.workout))
        let secondDayRequestAnchors = await fake.workoutRequestAnchors()
        XCTAssertEqual(
            secondDayRequestAnchors,
            [nil, Data([0xA3])],
            "The second-day sync must extend the verified marker through its anchor, without a nil-anchor full query"
        )
        XCTAssertEqual(
            try healthSnapshot(on: verifiedRestDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "An empty incremental page preserves previously verified coverage"
        )
        XCTAssertEqual(
            try healthSnapshot(on: today).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "The prior as-of day remains covered after a complete next-day incremental query"
        )
        let nextDay = calendar.startOfDay(for: nextDayNow)
        XCTAssertEqual(
            try healthSnapshot(on: nextDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "The current day is covered as of the complete incremental query time"
        )

        await fake.setWorkoutResponses([
            HealthChangePage(
                added: [],
                deletedObjectIDs: [witness.healthKitUUID],
                nextAnchorData: Data([0xA5])
            )
        ])
        let deletionResult = try await coordinator.syncAvailableData(using: repository, now: nextDayNow)
        XCTAssertTrue(deletionResult.completedStreams.contains(.workout))
        XCTAssertNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == witness.healthKitUUID
        })
        XCTAssertEqual(
            try healthSnapshot(on: witnessDay).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "Deleting the last workout after a verified full scan leaves the re-queried day as verified rest"
        )
    }

    func testIncrementalWorkoutEvidenceTriggersOneFullRequeryBeforeCoverage() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(
            through: now,
            calendar: calendar
        ))
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: calendar.startOfDay(for: now)))
        let workout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-0000000007A3",
            startedAt: day.addingTimeInterval(11 * 60 * 60)
        )
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: Data([0xA6]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try insertHealthSnapshot(
            on: day,
            readStates: [HealthMetricID.workout.rawValue: .dataUnavailableOrReadScopeUnknown]
        )
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([0xA7])),
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([0xAA])),
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNotNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workout.healthKitUUID
        }, "The targeted full query persists its read-scope witness")
        XCTAssertEqual(
            try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue],
            .available,
            "Coverage is promoted only after the nil-anchor full query completes with the witness"
        )
        let requestAnchors = await fake.workoutRequestAnchors()
        XCTAssertEqual(requestAnchors, [Data([0xA6]), nil])
    }

    func testManualWorkoutCannotWitnessHealthKitScopeForIncrementalRestDay() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(
            through: now,
            calendar: calendar
        ))
        let today = calendar.startOfDay(for: now)
        let priorDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: Data([0xA8]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        context.insert(WorkoutRecord(date: priorDay.addingTimeInterval(12 * 60 * 60), type: "manual"))
        try insertHealthSnapshot(
            on: priorDay,
            readStates: [HealthMetricID.workout.rawValue: .available]
        )
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [], deletedObjectIDs: [], nextAnchorData: Data([0xA9]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let nextDayNow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: nextDayNow
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertEqual(
            try healthSnapshot(on: today).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown,
            "A user-entered workout cannot serve as HealthKit authorization scope evidence"
        )
    }

    func testWorkoutPaginationUsesLatestChangeForDuplicateUUIDAcrossPages() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now.addingTimeInterval(-5 * 86_400))
        let addThenDeleteID = UUID(uuidString: "00000000-0000-0000-0000-000000000791")!
        let deleteThenAddID = UUID(uuidString: "00000000-0000-0000-0000-000000000792")!
        let addThenDelete = try makeWorkoutSnapshot(
            id: addThenDeleteID.uuidString,
            startedAt: day.addingTimeInterval(9 * 60 * 60)
        )
        let deleteThenAdd = try makeWorkoutSnapshot(
            id: deleteThenAddID.uuidString,
            startedAt: day.addingTimeInterval(14 * 60 * 60)
        )
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(
                added: [addThenDelete],
                deletedObjectIDs: [deleteThenAddID],
                nextAnchorData: Data([93]),
                hasMore: true
            ),
            HealthChangePage(
                added: [deleteThenAdd],
                deletedObjectIDs: [addThenDeleteID],
                nextAnchorData: Data([94])
            ),
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        let recordsByUUID = Dictionary(
            try context.fetch(FetchDescriptor<WorkoutRecord>()).compactMap { workout in
                workout.healthKitUUID.map { ($0, workout) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
        XCTAssertNil(recordsByUUID[addThenDeleteID])
        XCTAssertNotNil(recordsByUUID[deleteThenAddID])
        XCTAssertEqual(
            try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue],
            .available
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == "workouts" })?.anchorData, Data([94]))
    }

    func testWorkoutNonAdvancingChangedPageIsNotCommittedBeforeRebuild() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let day = calendar.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        let badAnchor = Data([0xF2])
        let rejectedPageWorkout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000798",
            startedAt: day.addingTimeInterval(9 * 60 * 60)
        )
        let rebuiltWorkout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000799",
            startedAt: day.addingTimeInterval(14 * 60 * 60)
        )
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: badAnchor,
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(
                added: [rejectedPageWorkout],
                deletedObjectIDs: [],
                nextAnchorData: badAnchor,
                hasMore: true
            ),
            HealthChangePage(added: [rebuiltWorkout], deletedObjectIDs: [], nextAnchorData: Data([102])),
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        XCTAssertNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == rejectedPageWorkout.healthKitUUID
        })
        XCTAssertNotNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == rebuiltWorkout.healthKitUUID
        })
        XCTAssertEqual(result.readRecordCount, 2)
        let attemptedAnchors = await fake.workoutRequestAnchors()
        XCTAssertEqual(attemptedAnchors, [badAnchor, nil])
    }

    func testEmptyTerminalWorkoutPageCanKeepItsAnchorWithoutClaimingAvailability() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let day = calendar.startOfDay(for: now.addingTimeInterval(-3 * 86_400))
        let existingAnchor = Data([103])
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: existingAnchor,
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try insertHealthSnapshot(
            on: day,
            readStates: [HealthMetricID.workout.rawValue: .dataUnavailableOrReadScopeUnknown]
        )
        try context.save()
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        let cursor = try HealthRepository(modelContext: context).cursor(for: "workouts")
        XCTAssertEqual(cursor?.anchorData, existingAnchor)
        XCTAssertEqual(
            try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )

    }

    func testInvalidWorkoutAnchorPurgesOnlyWorkoutAndRebuildsWithoutDroppingManualWorkout() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let day = calendar.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        let badAnchor = Data([0xEE, 0x01])
        let staleUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000793")!
        let rebuiltWorkout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000795",
            startedAt: day.addingTimeInterval(16 * 60 * 60)
        )
        context.insert(WorkoutRecord(
            date: day.addingTimeInterval(8 * 60 * 60),
            type: "running",
            durationMinutes: 20,
            estimatedCaloriesBurned: 90,
            intensity: "moderate",
            healthKitUUID: staleUUID,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue,
            energySource: WorkoutEnergySource.measured.rawValue
        ))
        context.insert(WorkoutRecord(
            date: day.addingTimeInterval(7 * 60 * 60),
            type: "cycling",
            durationMinutes: 25,
            intensity: "moderate"
        ))
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: badAnchor,
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        context.insert(HealthKitImportCursor(
            stream: HealthMetricID.bodyMass.rawValue,
            anchorData: Data([96]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.failNextWorkoutChangesWithInvalidAnchor()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [rebuiltWorkout], deletedObjectIDs: [], nextAnchorData: Data([97]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.workout))
        let records = try context.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertFalse(records.contains(where: { $0.healthKitUUID == staleUUID }))
        XCTAssertTrue(records.contains(where: { $0.healthKitUUID == rebuiltWorkout.healthKitUUID }))
        XCTAssertTrue(records.contains(where: { $0.type == "cycling" && $0.healthKitUUID == nil }))
        XCTAssertEqual(try HealthRepository(modelContext: context).cursor(for: "workouts")?.anchorData, Data([97]))
        XCTAssertEqual(
            try HealthRepository(modelContext: context).cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData,
            Data([96])
        )
        let requestAnchors = await fake.workoutRequestAnchors()
        XCTAssertEqual(requestAnchors.count, 2)
        XCTAssertEqual(requestAnchors[0], badAnchor)
        XCTAssertNil(requestAnchors[1])
    }

    func testInvalidSampleAnchorPurgesOnlyItsStreamAndRebuilds() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: Calendar.current)
        )
        try seedAnchoredCursors(targetStart: targetStart, now: now)
        let day = Calendar.current.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        let badAnchor = Data([0xEF, 0x02])
        let staleBodyMassID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let unrelatedHeartRateID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        context.insert(HealthKitSampleIndexRecord(
            sampleID: staleBodyMassID,
            stream: HealthMetricID.bodyMass.rawValue,
            dayKey: Self.dayKey(day, calendar: Calendar.current),
            startDate: day.addingTimeInterval(8 * 60 * 60),
            endDate: day.addingTimeInterval(8 * 60 * 60)
        ))
        context.insert(HealthKitSampleIndexRecord(
            sampleID: unrelatedHeartRateID,
            stream: HealthMetricID.heartRate.rawValue,
            dayKey: Self.dayKey(day, calendar: Calendar.current),
            startDate: day.addingTimeInterval(9 * 60 * 60),
            endDate: day.addingTimeInterval(9 * 60 * 60)
        ))
        let bodyMassCursor = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == HealthMetricID.bodyMass.rawValue }))
        bodyMassCursor.anchorData = badAnchor
        let unrelatedAnchor = Data([98])
        let heartRateCursor = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == HealthMetricID.heartRate.rawValue }))
        heartRateCursor.anchorData = unrelatedAnchor
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.failNextSampleChangesWithInvalidAnchor(for: .bodyMass)
        await fake.setSampleResponses([
            HealthSamplePage(samples: [], nextAnchorData: Data([99]), readState: .dataUnavailableOrReadScopeUnknown),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        XCTAssertNil(result.failedStreams[.bodyMass])
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].anchorData, badAnchor)
        XCTAssertNil(requests[1].anchorData)
        let repository = HealthRepository(modelContext: context)
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData, Data([99]))
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.heartRate.rawValue)?.anchorData, unrelatedAnchor)
        let remainingIndexIDs = Set(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).map(\.sampleID))
        XCTAssertFalse(remainingIndexIDs.contains(staleBodyMassID))
        XCTAssertTrue(remainingIndexIDs.contains(unrelatedHeartRateID))
    }

    func testNonAdvancingSamplePageIsNotCommittedBeforeTargetedRebuild() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let day = calendar.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        try seedAnchoredCursors(targetStart: targetStart, now: now)
        let badAnchor = Data([0xF3])
        let bodyMassCursor = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == HealthMetricID.bodyMass.rawValue }))
        bodyMassCursor.anchorData = badAnchor
        try context.save()
        let rejectedSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000798")!,
            metric: .bodyMass,
            startDate: day.addingTimeInterval(10 * 60 * 60),
            endDate: day.addingTimeInterval(10 * 60 * 60),
            value: 66
        )
        let rebuiltSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000799")!,
            metric: .bodyMass,
            startDate: day.addingTimeInterval(11 * 60 * 60),
            endDate: day.addingTimeInterval(11 * 60 * 60),
            value: 67
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(
                samples: [rejectedSample],
                nextAnchorData: badAnchor,
                hasMore: true,
                readState: .available
            ),
            HealthSamplePage(samples: [rebuiltSample], nextAnchorData: Data([105]), readState: .available),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        let indexIDs = try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            .filter { $0.stream == HealthMetricID.bodyMass.rawValue }
            .map(\.sampleID)
        XCTAssertFalse(indexIDs.contains(rejectedSample.id))
        XCTAssertTrue(indexIDs.contains(rebuiltSample.id))
        XCTAssertEqual(try HealthRepository(modelContext: context).cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData,
                       Data([105]))
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        XCTAssertEqual(requests[0].anchorData, badAnchor)
        XCTAssertNil(requests[1].anchorData)
    }

    func testEmptyTerminalSamplePageCanKeepItsAnchorWithoutRecovery() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: Calendar.current)
        )
        try seedAnchoredCursors(targetStart: targetStart, now: now)
        let existingAnchor = Data([106])
        let cursor = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == HealthMetricID.bodyMass.rawValue }))
        cursor.anchorData = existingAnchor
        try context.save()
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        XCTAssertNil(result.failedStreams[.bodyMass])
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].anchorData, existingAnchor)
        XCTAssertEqual(try HealthRepository(modelContext: context).cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData,
                       existingAnchor)
    }

    func testWorkoutAuthorizationPlanFailurePurgesOnlyWorkoutCache() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let day = calendar.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        let staleUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000800")!
        context.insert(WorkoutRecord(
            date: day.addingTimeInterval(8 * 60 * 60),
            type: "running",
            durationMinutes: 20,
            intensity: "moderate",
            healthKitUUID: staleUUID,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue,
            energySource: WorkoutEnergySource.measured.rawValue
        ))
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: Data([107]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        context.insert(HealthKitImportCursor(
            stream: HealthMetricID.bodyMass.rawValue,
            anchorData: Data([108]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try insertHealthSnapshot(on: day, readStates: [HealthMetricID.workout.rawValue: .available])
        try context.save()
        let gate = HealthContextExportGate(initiallyOpen: true)
        let fake = FakeHealthStoreClient()
        await fake.failAuthorizationBoundaryQuery(for: .workout)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        coordinator.onHealthCachePurgeWillBegin = { gate.closeForSnapshotRebuild() }
        coordinator.onHealthCachePurgeDidSucceed = { gate.openAfterSuccessfulPurge(generation: $0) }

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertNotNil(result.failedStreams[.workout])
        XCTAssertTrue(gate.isOpen, "The gate reopens only after the targeted purge commits")
        XCTAssertNil(try context.fetch(FetchDescriptor<WorkoutRecord>()).first { $0.healthKitUUID == staleUUID })
        XCTAssertEqual(try HealthRepository(modelContext: context).cursor(for: "workouts")?.anchorData, nil)
        XCTAssertEqual(
            try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        XCTAssertEqual(
            try HealthRepository(modelContext: context).cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData,
            Data([108])
        )
    }

    func testInvalidWorkoutAnchorRecoveryFailureLeavesUnknownAndRetryable() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let day = calendar.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        context.insert(WorkoutRecord(
            date: day.addingTimeInterval(8 * 60 * 60),
            type: "running",
            durationMinutes: 20,
            intensity: "moderate",
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000796")!,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue,
            energySource: WorkoutEnergySource.measured.rawValue
        ))
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: Data([0xF0]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.failNextWorkoutChangesWithInvalidAnchor(2)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertNotNil(result.failedStreams[.workout])
        let attemptedAnchors = await fake.workoutRequestAnchors()
        XCTAssertEqual(attemptedAnchors.count, 2)
        XCTAssertEqual(attemptedAnchors, [Data([0xF0]), nil])
        XCTAssertNil(try HealthRepository(modelContext: context).cursor(for: "workouts")?.anchorData)
        XCTAssertFalse(try context.fetch(FetchDescriptor<WorkoutRecord>()).contains {
            $0.healthKitUUID != nil
        })
        XCTAssertEqual(
            try healthSnapshot(on: day).healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )

        let recoveredWorkout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000803",
            startedAt: day.addingTimeInterval(12 * 60 * 60)
        )
        await fake.setWorkoutResponses([
            HealthChangePage(added: [recoveredWorkout], deletedObjectIDs: [], nextAnchorData: Data([0xF2]))
        ])
        let retried = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now
        )
        XCTAssertTrue(retried.completedStreams.contains(.workout))
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).contains {
            $0.healthKitUUID == recoveredWorkout.healthKitUUID
        })
        XCTAssertEqual(try HealthRepository(modelContext: context).cursor(for: "workouts")?.anchorData, Data([0xF2]))
    }

    func testObserverRecoversInvalidWorkoutAnchorAndNextWakeupUsesNewCursor() async throws {
        let now = Date()
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar))
        let badAnchor = Data([0xF1])
        let day = calendar.startOfDay(for: now.addingTimeInterval(-4 * 86_400))
        let workout = try makeWorkoutSnapshot(
            id: "00000000-0000-0000-0000-000000000797",
            startedAt: day.addingTimeInterval(12 * 60 * 60)
        )
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: badAnchor,
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        try context.save()
        let fake = FakeHealthStoreClient()
        await fake.failNextWorkoutChangesWithInvalidAnchor()
        await fake.setWorkoutResponses([
            HealthChangePage(added: [workout], deletedObjectIDs: [], nextAnchorData: Data([100]))
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        var observerRefreshCount = 0
        coordinator.onObserverSyncCompleted = { _, _ in observerRefreshCount += 1 }
        let repository = HealthRepository(modelContext: context)
        try await coordinator.startBackgroundObservers(using: repository)

        let initialCompletions = await fake.completedObserverCount()
        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: initialCompletions)
        let firstWakeupCompletions = await fake.completedObserverCount()
        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: firstWakeupCompletions)

        XCTAssertEqual(observerRefreshCount, 2)
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([100]))
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).contains {
            $0.healthKitUUID == workout.healthKitUUID
        })
        let requestAnchors = await fake.workoutRequestAnchors()
        XCTAssertEqual(requestAnchors.count, 3)
        XCTAssertEqual(requestAnchors[0], badAnchor)
        XCTAssertNil(requestAnchors[1])
        XCTAssertEqual(requestAnchors[2], Data([100]))
    }

    func testHealthContextExportGateStartsClosedAndOpensAfterSuccessfulPurge() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = HealthContextExportGate()
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        coordinator.onHealthCachePurgeWillBegin = {
            gate.closeForSnapshotRebuild()
        }
        coordinator.onHealthCachePurgeDidSucceed = { generation in
            gate.openAfterSuccessfulPurge(generation: generation)
        }

        XCTAssertFalse(gate.isOpen)
        let repository = HealthRepository(modelContext: context)
        _ = try await coordinator.prepareForegroundSnapshotRebuild(using: repository, now: now)

        XCTAssertTrue(gate.isOpen)
        let exportedValue = try await gate.withAllowedExport { "current-health-context" }
        XCTAssertEqual(exportedValue, "current-health-context")
    }

    func testHealthContextExportGateCanAllowManualOnlyContextWithoutHealthKitCache() async throws {
        let gate = HealthContextExportGate(initiallyOpen: true)
        XCTAssertTrue(gate.isOpen)
        let exportedValue = try await gate.withAllowedExport { "manual-health-context" }
        XCTAssertEqual(exportedValue, "manual-health-context")
    }

    func testForegroundActivationClosesAuthorizedExportGateBeforeSchedulingWork() async throws {
        let gate = HealthContextExportGate(initiallyOpen: true)
        var exportAttempt: Task<Bool, Never>?
        let rebaselineCoordinator = ForegroundHealthRebaselineCoordinator(
            operation: { _, _ in
                HealthSyncResult(completedStreams: HealthKitSyncCoordinator.observedStreams, failedStreams: [:])
            }
        )

        rebaselineCoordinator.prepareActivation {
            gate.closeForForegroundActivation(hasRequestedAuthorization: true)
            XCTAssertFalse(gate.isOpen, "The gate must close synchronously before async work is scheduled")
            XCTAssertNotNil(gate.foregroundPurgeHoldToken)
            exportAttempt = Task { @MainActor in
                do {
                    _ = try await gate.withAllowedExport { "stale-health-context" }
                    return false
                } catch is HealthContextExportGateError {
                    return true
                } catch {
                    return false
                }
            }
        }

        XCTAssertFalse(gate.isOpen)
        let exportWasRejected = try XCTUnwrap(exportAttempt)
        let wasRejected = await exportWasRejected.value
        XCTAssertTrue(wasRejected)
    }

    func testUnauthenticatedForegroundActivationKeepsOpenManualOnlyGate() async throws {
        let gate = HealthContextExportGate(initiallyOpen: true)
        gate.closeForForegroundActivation(hasRequestedAuthorization: false)
        XCTAssertTrue(gate.isOpen)
        XCTAssertNil(gate.foregroundPurgeHoldToken)
        let exportedValue = try await gate.withAllowedExport { "manual-health-context" }
        XCTAssertEqual(exportedValue, "manual-health-context")
    }

    func testUnauthenticatedActivationPurgesCacheAfterAuthorizationPreferenceIsCleared() {
        let gate = HealthContextExportGate(initiallyOpen: true)

        gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        let authorizedHold = gate.foregroundPurgeHoldToken
        gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(authorizedHold)
        XCTAssertTrue(gate.isOpen)

        gate.closeForForegroundActivation(hasRequestedAuthorization: false)
        let unauthorizedHold = gate.foregroundPurgeHoldToken
        XCTAssertFalse(gate.isOpen, "Previously cached HealthKit data must be gated before the local purge")
        XCTAssertNotNil(unauthorizedHold)

        gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(
            unauthorizedHold,
            healthKitCacheMayRemain: false
        )
        XCTAssertTrue(gate.isOpen)

        gate.closeForForegroundActivation(hasRequestedAuthorization: false)
        XCTAssertTrue(gate.isOpen, "A completed local purge restores manual-only health context")
        XCTAssertNil(gate.foregroundPurgeHoldToken)
    }

    func testUnauthenticatedClosedGateOpensAfterLocalSnapshotPurgeSucceeds() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = HealthContextExportGate()
        gate.closeForForegroundActivation(hasRequestedAuthorization: false)
        let holdToken = try XCTUnwrap(gate.foregroundPurgeHoldToken)

        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        coordinator.onHealthCachePurgeWillBegin = {
            gate.closeForSnapshotRebuild()
        }
        coordinator.onHealthCachePurgeDidSucceed = { generation in
            gate.openAfterSuccessfulPurge(generation: generation)
        }
        _ = try await coordinator.prepareForegroundSnapshotRebuild(
            using: HealthRepository(modelContext: context),
            now: now
        )

        XCTAssertFalse(gate.isOpen)
        gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(
            holdToken,
            healthKitCacheMayRemain: false
        )
        XCTAssertTrue(gate.isOpen)
        let exportedValue = try await gate.withAllowedExport { "manual-health-context" }
        XCTAssertEqual(exportedValue, "manual-health-context")
    }

    func testForegroundActivationInvalidatesAnOlderPurgeReopenToken() {
        let gate = HealthContextExportGate(initiallyOpen: true)
        let olderPurgeGeneration = gate.closeForSnapshotRebuild()

        gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        gate.openAfterSuccessfulPurge(generation: olderPurgeGeneration)

        XCTAssertFalse(gate.isOpen)
        XCTAssertNotNil(gate.foregroundPurgeHoldToken)
    }

    func testRepeatedForegroundPreparationPreservesHoldTokenForSuccessfulPurgeRelease() throws {
        let gate = HealthContextExportGate(initiallyOpen: true)
        let coordinator = ForegroundHealthRebaselineCoordinator(operation: { _, _ in
            HealthSyncResult(completedStreams: HealthKitSyncCoordinator.observedStreams, failedStreams: [:])
        })
        coordinator.prepareActivation {
            gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        }
        let successfulPurgeToken = try XCTUnwrap(gate.foregroundPurgeHoldToken)

        coordinator.prepareActivation {
            gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        }

        XCTAssertEqual(gate.foregroundPurgeHoldToken, successfulPurgeToken)
        let purgeGeneration = gate.closeForSnapshotRebuild()
        gate.openAfterSuccessfulPurge(generation: purgeGeneration)
        XCTAssertFalse(gate.isOpen)

        gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(successfulPurgeToken)

        XCTAssertNil(gate.foregroundPurgeHoldToken)
        XCTAssertTrue(gate.isOpen)
    }

    func testForegroundPurgeHoldBlocksObserverPurgeUntilWholeSnapshotPurgeSucceeds() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = HealthContextExportGate(initiallyOpen: true)
        let foregroundCoordinator = ForegroundHealthRebaselineCoordinator(operation: { _, _ in
            HealthSyncResult(completedStreams: HealthKitSyncCoordinator.observedStreams, failedStreams: [:])
        })
        foregroundCoordinator.prepareActivation {
            gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        }
        let holdToken = try XCTUnwrap(gate.foregroundPurgeHoldToken)

        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        coordinator.onHealthCachePurgeWillBegin = {
            gate.closeForSnapshotRebuild()
        }
        coordinator.onHealthCachePurgeDidSucceed = { generation in
            gate.openAfterSuccessfulPurge(generation: generation)
        }

        // Model an independent observer's scoped purge committing before the
        // foreground full-window purge has started.
        let observerPurgeGeneration = try XCTUnwrap(coordinator.onHealthCachePurgeWillBegin?())
        coordinator.onHealthCachePurgeDidSucceed?(observerPurgeGeneration)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.foregroundPurgeHoldToken, holdToken)

        _ = try await coordinator.prepareForegroundSnapshotRebuild(
            using: HealthRepository(modelContext: context),
            now: now
        )
        XCTAssertFalse(gate.isOpen, "The full purge callback remains held until its preparation returns")
        XCTAssertEqual(gate.foregroundPurgeHoldToken, holdToken)

        gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(holdToken)
        XCTAssertNil(gate.foregroundPurgeHoldToken)
        XCTAssertTrue(gate.isOpen)
    }

    func testPreparedTimezoneMismatchReclosesGateAfterPurgeCallback() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = HealthContextExportGate()
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        coordinator.onHealthCachePurgeWillBegin = {
            gate.closeForSnapshotRebuild()
        }
        coordinator.onHealthCachePurgeDidSucceed = { generation in
            gate.openAfterSuccessfulPurge(generation: generation)
        }
        let repository = HealthRepository(modelContext: context)
        gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        let holdToken = try XCTUnwrap(gate.foregroundPurgeHoldToken)
        let prepared = try await coordinator.prepareForegroundSnapshotRebuild(using: repository, now: now)
        XCTAssertFalse(gate.isOpen, "The purge callback is held until the full preparation succeeds")
        gate.releaseForegroundPurgeHoldAfterSuccessfulSnapshotRebuild(holdToken)
        XCTAssertTrue(gate.isOpen)

        let stalePreparation = HealthKitSnapshotRebuildPreparation(
            windowStart: prepared.windowStart,
            through: prepared.through,
            timeZoneIdentifier: "\(prepared.timeZoneIdentifier).previous"
        )
        do {
            _ = try await coordinator.syncAvailableData(
                using: repository,
                now: stalePreparation.through,
                forceRebaseline: true,
                preparedSnapshotRebuild: stalePreparation
            )
            XCTFail("A prepared snapshot token from another time zone must fail closed")
        } catch {
            _ = gate.ensureForegroundPurgeHold()
        }

        XCTAssertFalse(gate.isOpen)
        XCTAssertNotNil(gate.foregroundPurgeHoldToken)
    }

    func testHealthContextExportGateStaysClosedWhenForegroundPurgeFails() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let gate = HealthContextExportGate()
        gate.closeForForegroundActivation(hasRequestedAuthorization: true)
        let holdToken = try XCTUnwrap(gate.foregroundPurgeHoldToken)
        let fake = FakeHealthStoreClient()
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        coordinator.onHealthCachePurgeWillBegin = {
            gate.closeForSnapshotRebuild()
        }
        coordinator.onHealthCachePurgeDidSucceed = { generation in
            gate.openAfterSuccessfulPurge(generation: generation)
        }
        let failingRepository = HealthRepository(modelContext: context, willSave: {
            throw NSError(domain: "HealthSnapshotPurge", code: 1)
        })

        do {
            try await coordinator.prepareForegroundSnapshotRebuild(using: failingRepository, now: now)
            XCTFail("Expected the injected save failure")
        } catch {}
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.foregroundPurgeHoldToken, holdToken)
        let unrelatedPurgeGeneration = gate.closeForSnapshotRebuild()
        gate.openAfterSuccessfulPurge(generation: unrelatedPurgeGeneration)
        XCTAssertFalse(gate.isOpen, "An unrelated purge success must not release a failed full-purge hold")
        var exportWasRejected = false
        do {
            _ = try await gate.withAllowedExport { "stale-health-context" }
        } catch is HealthContextExportGateError {
            exportWasRejected = true
        }
        XCTAssertTrue(exportWasRejected)
    }

    func testHealthContextExportGateRejectsAnExportCrossingARebaseline() async throws {
        let gate = HealthContextExportGate()
        let generation = gate.closeForSnapshotRebuild()
        gate.openAfterSuccessfulPurge(generation: generation)
        var rejected = false

        do {
            _ = try await gate.withAllowedExport {
                _ = await gate.closeForSnapshotRebuild()
                return "pre-rebaseline-context"
            }
        } catch is HealthContextExportGateError {
            rejected = true
        }

        XCTAssertTrue(rejected)
        XCTAssertFalse(gate.isOpen)
    }

    func testForegroundPurgeSupersedesAnInFlightDailyRebaselineBeforeItCanWrite() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let sampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        let staleID = UUID(uuidString: "00000000-0000-0000-0000-000000000741")!
        let staleSample = HealthSampleSnapshot(
            id: staleID,
            metric: .bodyMass,
            startDate: sampleDay.addingTimeInterval(3_600),
            endDate: sampleDay.addingTimeInterval(3_600),
            value: 987.654321
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(samples: [staleSample], nextAnchorData: Data([41]), readState: .available),
        ], for: .bodyMass)
        await fake.blockNextSampleResponse(for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let repository = HealthRepository(modelContext: context)
        defer { Task { await fake.resumeBlockedSampleResponse(for: .bodyMass) } }

        let dailyRefresh = Task { @MainActor in
            try await coordinator.syncAvailableData(using: repository, now: now, forceRebaseline: true)
        }
        await fake.waitUntilSampleResponseIsBlocked(for: .bodyMass)
        _ = try await coordinator.prepareForegroundSnapshotRebuild(using: repository, now: now)
        await fake.resumeBlockedSampleResponse(for: .bodyMass)

        var dailyRefreshWasSuperseded = false
        do {
            _ = try await dailyRefresh.value
        } catch {
            dailyRefreshWasSuperseded = true
        }
        XCTAssertTrue(dailyRefreshWasSuperseded)
        XCTAssertFalse(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            .contains(where: { $0.sampleID == staleID }))
        let dayKey = Self.dayKey(sampleDay, calendar: calendar)
        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testDailyRebaselineSupersedesAnInFlightForegroundRebaseline() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let sampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        let staleID = UUID(uuidString: "00000000-0000-0000-0000-000000000743")!
        let staleSample = HealthSampleSnapshot(
            id: staleID,
            metric: .bodyMass,
            startDate: sampleDay.addingTimeInterval(3_600),
            endDate: sampleDay.addingTimeInterval(3_600),
            value: 85.654321
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(samples: [staleSample], nextAnchorData: Data([43]), readState: .available),
            HealthSamplePage(samples: [], nextAnchorData: Data([44]), readState: .dataUnavailableOrReadScopeUnknown),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let repository = HealthRepository(modelContext: context)
        let preparation = try await coordinator.prepareForegroundSnapshotRebuild(using: repository, now: now)
        await fake.blockNextSampleResponse(for: .bodyMass)
        defer { Task { await fake.resumeBlockedSampleResponse(for: .bodyMass) } }

        let foregroundRefresh = Task { @MainActor in
            try await coordinator.syncAvailableData(
                using: repository,
                now: now,
                forceRebaseline: true,
                preparedSnapshotRebuild: preparation
            )
        }
        await fake.waitUntilSampleResponseIsBlocked(for: .bodyMass)
        let dailyRefresh = try await coordinator.syncAvailableData(
            using: repository,
            now: now,
            forceRebaseline: true
        )
        await fake.resumeBlockedSampleResponse(for: .bodyMass)

        XCTAssertTrue(dailyRefresh.completedStreams.contains(.bodyMass))
        var foregroundRefreshWasSuperseded = false
        do {
            _ = try await foregroundRefresh.value
        } catch {
            foregroundRefreshWasSuperseded = true
        }
        XCTAssertTrue(foregroundRefreshWasSuperseded)
        XCTAssertFalse(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            .contains(where: { $0.sampleID == staleID }))
        let dayKey = Self.dayKey(sampleDay, calendar: calendar)
        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testForegroundPurgeSupersedesAnInFlightObserverAndSkipsItsRefreshCallback() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let sampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        let staleID = UUID(uuidString: "00000000-0000-0000-0000-000000000742")!
        let staleSample = HealthSampleSnapshot(
            id: staleID,
            metric: .bodyMass,
            startDate: sampleDay.addingTimeInterval(3_600),
            endDate: sampleDay.addingTimeInterval(3_600),
            value: 876.543219
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(samples: [staleSample], nextAnchorData: Data([42]), readState: .available),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let repository = HealthRepository(modelContext: context)
        var observerRefreshCount = 0
        coordinator.onObserverSyncCompleted = { _, _ in observerRefreshCount += 1 }
        try await coordinator.startBackgroundObservers(using: repository)
        let previousCompletions = await fake.completedObserverCount()
        await fake.blockNextSampleResponse(for: .bodyMass)
        defer { Task { await fake.resumeBlockedSampleResponse(for: .bodyMass) } }

        await fake.triggerObserver(.bodyMass)
        await fake.waitUntilSampleResponseIsBlocked(for: .bodyMass)
        _ = try await coordinator.prepareForegroundSnapshotRebuild(using: repository, now: now)
        await fake.resumeBlockedSampleResponse(for: .bodyMass)
        await fake.waitForObserverCompletion(after: previousCompletions)

        XCTAssertEqual(observerRefreshCount, 0)
        XCTAssertFalse(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            .contains(where: { $0.sampleID == staleID }))
        let dayKey = Self.dayKey(sampleDay, calendar: calendar)
        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testUnavailableBoundaryRebuildsOnlyAffectedStreamsAndAggregateFailureStaysUnknown() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([21]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now,
            lookbackStart: targetStart,
            replacements: []
        )
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([22]), readState: .available),
            stream: HealthMetricID.heartRate.rawValue,
            lastSuccessfulAt: now,
            lookbackStart: targetStart,
            replacements: []
        )
        try await repository.applyImportedWorkouts(
            [],
            deletedHealthKitUUIDs: [],
            nextAnchorData: Data([23]),
            lookbackStart: targetStart
        )
        try await repository.applyHealthAggregates(
            [HealthAggregateBucket(
                startDate: targetStart,
                endDate: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: targetStart)),
                value: 500
            )],
            metric: .activeEnergy,
            stream: HealthMetricID.activeEnergy.rawValue,
            lookbackStart: targetStart,
            through: now,
            lastSuccessfulAt: now
        )
        let fake = FakeHealthStoreClient()
        await fake.failAuthorizationBoundaryLookup(for: .bodyMass)
        await fake.failAuthorizationBoundaryLookup(for: .activeEnergy)
        await fake.failAggregate(for: .activeEnergy)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        XCTAssertNotNil(result.failedStreams[.activeEnergy])
        let rebuiltMetricCursor = try XCTUnwrap(repository.cursor(for: HealthMetricID.bodyMass.rawValue))
        XCTAssertEqual(rebuiltMetricCursor.anchorData, Data([0]))
        XCTAssertEqual(rebuiltMetricCursor.lookbackStart, targetStart)
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.heartRate.rawValue)?.anchorData, Data([22]))
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([23]))
        XCTAssertNil(try repository.cursor(for: HealthMetricID.activeEnergy.rawValue)?.lookbackStart)
        let targetSnapshot = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == Self.dayKey(targetStart, calendar: calendar) }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let decodedTargetSnapshot = try decoder.decode(DailyHealthSnapshot.self, from: targetSnapshot.payloadData)
        XCTAssertNil(decodedTargetSnapshot.activeEnergyKcal)
        XCTAssertEqual(
            decodedTargetSnapshot.healthReadStates?[HealthMetricID.activeEnergy.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )

        _ = try await coordinator.syncAvailableData(using: repository, now: now, forceRebaseline: true)

        let heartRateRequests = await fake.sampleRequests(for: .heartRate)
        XCTAssertNil(heartRateRequests.last?.anchorData)
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([0]))
        XCTAssertNil(try repository.cursor(for: HealthMetricID.activeEnergy.rawValue)?.lookbackStart)
    }

    func testObserverWithUnavailableBoundaryRebuildsExistingSampleAndWorkoutAnchors() async throws {
        // Observer-triggered syncs use Date() internally, so keep the fixture
        // window aligned with the callback's clock instead of a stale fixed date.
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let sampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: today))
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000740")!,
            metric: .bodyMass,
            startDate: sampleDay.addingTimeInterval(3_600),
            endDate: sampleDay.addingTimeInterval(3_600),
            value: 71
        )
        let workout = try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000743")!,
            startedAt: sampleDay.addingTimeInterval(7_200),
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 250),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([8]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now,
            lookbackStart: targetStart,
            replacements: [HealthSampleDaySnapshot(dayStart: sampleDay, samples: [sample], readState: .available)]
        )
        try await repository.applyImportedWorkouts(
            [workout],
            deletedHealthKitUUIDs: [],
            nextAnchorData: Data([9]),
            lookbackStart: targetStart
        )
        let fake = FakeHealthStoreClient()
        await fake.failAuthorizationBoundaryLookup(for: .bodyMass)
        await fake.failAuthorizationBoundaryLookup(for: .workout)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        try await coordinator.startBackgroundObservers(using: repository)

        await fake.triggerObserver(.bodyMass)
        await fake.waitForObserverCompletion(after: 0)
        await fake.triggerObserver(.workout)
        await fake.waitForObserverCompletion(after: 1)

        let cursor = try XCTUnwrap(repository.cursor(for: HealthMetricID.bodyMass.rawValue))
        XCTAssertEqual(cursor.anchorData, Data([0]))
        XCTAssertEqual(cursor.lookbackStart, targetStart)
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requests.first?.startDate, targetStart)
        XCTAssertNil(requests.first?.anchorData)
        let workoutCursor = try XCTUnwrap(repository.cursor(for: "workouts"))
        XCTAssertEqual(workoutCursor.anchorData, Data([0]))
        XCTAssertEqual(workoutCursor.lookbackStart, targetStart)
        let workoutStarts = await fake.workoutRequestStartDates()
        XCTAssertEqual(workoutStarts.first, targetStart)

        XCTAssertFalse(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            .contains(where: { $0.sampleID == sample.id }))
        XCTAssertFalse(try context.fetch(FetchDescriptor<WorkoutRecord>())
            .contains(where: { $0.healthKitUUID == workout.healthKitUUID }))
        let dayKey = Self.dayKey(sampleDay, calendar: calendar)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        XCTAssertEqual(
            snapshot.healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }

    func testSnapshotRebuildPurgesOnlyWindowHealthKitCacheAndPreservesManualWeights() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let today = calendar.startOfDay(for: now)
        let inWindowDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: today))
        let outsideWindowDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: targetStart))
        let inWindowID = UUID(uuidString: "00000000-0000-0000-0000-000000000741")!
        let outsideWindowID = UUID(uuidString: "00000000-0000-0000-0000-000000000742")!
        let inWindowSample = HealthSampleSnapshot(
            id: inWindowID,
            metric: .bodyMass,
            startDate: inWindowDay.addingTimeInterval(3_600),
            endDate: inWindowDay.addingTimeInterval(3_600),
            value: 72
        )
        let outsideWindowSample = HealthSampleSnapshot(
            id: outsideWindowID,
            metric: .bodyMass,
            startDate: outsideWindowDay.addingTimeInterval(3_600),
            endDate: outsideWindowDay.addingTimeInterval(3_600),
            value: 70
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(
                samples: [inWindowSample, outsideWindowSample],
                nextAnchorData: Data([31]),
                readState: .available
            ),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now,
            lookbackStart: outsideWindowDay,
            replacements: [
                HealthSampleDaySnapshot(dayStart: inWindowDay, samples: [inWindowSample], readState: .available),
                HealthSampleDaySnapshot(dayStart: outsideWindowDay, samples: [outsideWindowSample], readState: .available),
            ]
        )
        context.insert(WeightRecord(
            sourceActionKey: "gate19-healthkit-weight",
            measuredAt: inWindowDay.addingTimeInterval(7_200),
            kilograms: 72,
            source: "healthKit",
            algorithmVersion: "healthkit-v1"
        ))
        context.insert(WeightRecord(
            sourceActionKey: "gate19-manual-weight",
            measuredAt: inWindowDay.addingTimeInterval(10_800),
            kilograms: 68,
            source: "manual",
            algorithmVersion: "weight-v3"
        ))
        context.insert(DailyBriefRecord(
            cacheKey: "daily:pre-rebaseline",
            dayKey: Self.dayKey(inWindowDay, calendar: calendar),
            snapshotHash: "pre-rebaseline-daily",
            algorithmVersion: "brief-v1",
            payloadData: Data([1])
        ))
        context.insert(WeeklyBriefRecord(
            cacheKey: "weekly:pre-rebaseline",
            weekKey: "pre-rebaseline-week",
            snapshotHash: "pre-rebaseline-weekly",
            algorithmVersion: "brief-v1",
            payloadData: Data([2])
        ))
        try context.save()

        let fake = FakeHealthStoreClient()
        await fake.failAuthorizationBoundaryLookup(for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        let indexes = try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
        XCTAssertFalse(indexes.contains(where: { $0.sampleID == inWindowID }))
        XCTAssertTrue(indexes.contains(where: { $0.sampleID == outsideWindowID }))
        let weights = try context.fetch(FetchDescriptor<WeightRecord>())
        XCTAssertFalse(weights.contains(where: {
            $0.source == "healthKit" && $0.measuredAt >= targetStart && $0.measuredAt < calendar.date(byAdding: .day, value: 1, to: today)!
        }))
        XCTAssertTrue(weights.contains(where: { $0.source == "manual" && $0.kilograms == 68 }))
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyBriefRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WeeklyBriefRecord>()).isEmpty)

        let records = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let inWindowRecord = try XCTUnwrap(records.first(where: {
            $0.dayKey == Self.dayKey(inWindowDay, calendar: calendar)
        }))
        let inWindowSnapshot = try decoder.decode(DailyHealthSnapshot.self, from: inWindowRecord.payloadData)
        XCTAssertNil(inWindowSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertEqual(inWindowSnapshot.weightKilograms, 68)
        XCTAssertEqual(
            inWindowSnapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        let outsideRecord = try XCTUnwrap(records.first(where: {
            $0.dayKey == Self.dayKey(outsideWindowDay, calendar: calendar)
        }))
        let outsideSnapshot = try decoder.decode(DailyHealthSnapshot.self, from: outsideRecord.payloadData)
        XCTAssertEqual(outsideSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 70)
    }

    func testAuthorizationBoundaryMaskClearsDerivedBriefCaches() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: now)
        context.insert(DailyBriefRecord(
            cacheKey: "daily:boundary-mask",
            dayKey: Self.dayKey(day, calendar: .current),
            snapshotHash: "pre-boundary-mask-daily",
            algorithmVersion: "brief-v1",
            payloadData: Data([1])
        ))
        context.insert(WeeklyBriefRecord(
            cacheKey: "weekly:boundary-mask",
            weekKey: "boundary-mask-week",
            snapshotHash: "pre-boundary-mask-weekly",
            algorithmVersion: "brief-v1",
            payloadData: Data([2])
        ))
        try context.save()

        let repository = HealthRepository(modelContext: context)
        try await repository.maskCachedHealthDataBeforeAuthorizationBoundary(
            for: .bodyMass,
            authorizationStart: now,
            through: now
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyBriefRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WeeklyBriefRecord>()).isEmpty)
    }

    func testReadModelHidesAggregateHealthValuesWhenTheirReadStatesAreUnknown() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let repository = HealthRepository(modelContext: context)
        let aggregateCases: [(HealthMetricID, Double)] = [
            (HealthMetricID.activeEnergy, 640.0),
            (.stepCount, 8_000.0),
            (.exerciseMinutes, 55.0),
        ]
        for (metric, value) in aggregateCases {
            try await repository.applyHealthAggregates(
                [HealthAggregateBucket(startDate: day, endDate: nextDay, value: value)],
                metric: metric,
                stream: metric.rawValue,
                lookbackStart: day,
                through: now
            )
        }
        let fake = FakeHealthStoreClient()
        await fake.failAuthorizationBoundaryLookup(for: .activeEnergy)
        await fake.failAuthorizationBoundaryLookup(for: .stepCount)
        await fake.failAuthorizationBoundaryLookup(for: .exerciseMinutes)
        await fake.failAggregate(for: .activeEnergy)
        await fake.failAggregate(for: .stepCount)
        await fake.failAggregate(for: .exerciseMinutes)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertNotNil(result.failedStreams[.activeEnergy])
        XCTAssertNotNil(result.failedStreams[.stepCount])
        XCTAssertNotNil(result.failedStreams[.exerciseMinutes])
        let days = try HealthIntelligenceReadModel(calendar: calendar).loadDays(through: now, in: context)
        let projectedDay = try XCTUnwrap(days.first(where: { calendar.startOfDay(for: $0.dayStart) == day }))
        XCTAssertNil(projectedDay.activeEnergyKcal)
        XCTAssertNil(projectedDay.stepCount)
        XCTAssertNil(projectedDay.exerciseMinutes)
    }

    func testAuthorizationBoundaryAdvanceRebaselinesAndExcludesPreviouslyIndexedSamples() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let authorizationStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let oldSampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: targetStart))
        let oldSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000734")!,
            metric: .bodyMass,
            startDate: oldSampleDay.addingTimeInterval(3_600),
            endDate: oldSampleDay.addingTimeInterval(3_600),
            value: 73
        )
        let olderSampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: targetStart))
        let olderSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000735")!,
            metric: .bodyMass,
            startDate: olderSampleDay.addingTimeInterval(3_600),
            endDate: olderSampleDay.addingTimeInterval(3_600),
            value: 68
        )
        let recentQueryStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -20, to: today))
        let staleWorkout = try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000736")!,
            startedAt: recentQueryStart.addingTimeInterval(-5 * 86_400),
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 250),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
        let staleHealthKitWeight = WeightRecord(
            sourceActionKey: "healthkit-boundary-\(UUID().uuidString)",
            measuredAt: olderSample.startDate,
            kilograms: 68,
            source: "healthKit"
        )
        context.insert(staleHealthKitWeight)
        try context.save()
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [oldSample, olderSample], nextAnchorData: Data([9]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now,
            lookbackStart: targetStart,
            replacements: [
                HealthSampleDaySnapshot(dayStart: oldSampleDay, samples: [oldSample], readState: .available),
                HealthSampleDaySnapshot(dayStart: olderSampleDay, samples: [olderSample], readState: .available),
            ]
        )
        try await repository.applyImportedWorkouts(
            [staleWorkout],
            deletedHealthKitUUIDs: [],
            nextAnchorData: Data([8]),
            lookbackStart: targetStart
        )
        let fake = FakeHealthStoreClient()
        await fake.setEarliestAuthorizedSampleDate(authorizationStart, for: .bodyMass)
        await fake.setEarliestAuthorizedSampleDate(recentQueryStart, for: .workout)
        await fake.setSampleResponses([
            HealthSamplePage(
                samples: [],
                nextAnchorData: Data([10]),
                readState: .dataUnavailableOrReadScopeUnknown
            ),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        guard result.completedStreams.contains(.bodyMass) else {
            let detail = result.failedStreams[.bodyMass]?.diagnosticSafeDetail ?? "no bodyMass failure detail recorded"
            XCTFail("Authorization-boundary rebaseline did not complete for bodyMass: \(detail)")
            return
        }
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(try XCTUnwrap(requests.first).startDate, authorizationStart)
        XCTAssertNil(requests.first?.anchorData)
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.lookbackStart, authorizationStart)
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData, Data([10]))
        let oldDayKey = Self.dayKey(oldSampleDay, calendar: calendar)
        let oldSnapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == oldDayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let oldSnapshot = try decoder.decode(DailyHealthSnapshot.self, from: oldSnapshotRecord.payloadData)
        XCTAssertEqual(
            oldSnapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        XCTAssertNil(oldSnapshot.weightKilograms)
        let olderDayKey = Self.dayKey(olderSampleDay, calendar: calendar)
        let olderSnapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == olderDayKey }))
        let olderSnapshot = try decoder.decode(DailyHealthSnapshot.self, from: olderSnapshotRecord.payloadData)
        XCTAssertEqual(
            olderSnapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        XCTAssertNil(olderSnapshot.weightKilograms)
        XCTAssertNil(olderSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertNil(try HealthKitWeightObservationReader.latestObservation(in: context, effectiveAt: now))
        XCTAssertFalse(try context.fetch(FetchDescriptor<WeightRecord>())
            .contains(where: { $0.source == "healthKit" && $0.id == staleHealthKitWeight.id }))
        XCTAssertFalse(try context.fetch(FetchDescriptor<WorkoutRecord>())
            .contains(where: { $0.healthKitUUID == staleWorkout.healthKitUUID }))

        let days = try HealthIntelligenceReadModel(calendar: calendar).loadDays(through: now, in: context)
        let oldDay = try XCTUnwrap(days.first(where: { calendar.startOfDay(for: $0.dayStart) == oldSampleDay }))
        XCTAssertTrue(oldDay.weightSamplesKilograms.isEmpty)
    }

    func testSubsequentSampleSyncUsesStoredAnchorInsteadOfReplayingThe42DayWindow() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now.addingTimeInterval(-60),
            lookbackStart: targetStart,
            replacements: []
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(
                samples: [],
                nextAnchorData: Data([2]),
                readState: .dataUnavailableOrReadScopeUnknown
            ),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.startDate, targetStart)
        XCTAssertEqual(requests.first?.endDate, .distantFuture)
        XCTAssertEqual(requests.first?.anchorData, Data([1]))
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData, Data([2]))
    }

    func testStoredSampleAnchorAppliesLateSamplesBeforeCurrentWindowStart() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let storedStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: targetStart))
        let sampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: targetStart))
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000737")!,
            metric: .bodyMass,
            startDate: sampleDay.addingTimeInterval(3_600),
            endDate: sampleDay.addingTimeInterval(3_600),
            value: 71
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now.addingTimeInterval(-60),
            lookbackStart: storedStart,
            replacements: []
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(samples: [sample], nextAnchorData: Data([2]), readState: .available),
            HealthSamplePage(samples: [sample], nextAnchorData: Data([3]), readState: .available),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].startDate, storedStart)
        XCTAssertEqual(requests[0].endDate, .distantFuture)
        XCTAssertEqual(requests[0].anchorData, Data([1]))
        XCTAssertEqual(requests[1].startDate, sampleDay)
        XCTAssertEqual(requests[1].endDate, calendar.date(byAdding: .day, value: 1, to: sampleDay))
        XCTAssertNil(requests[1].anchorData)
        let dayKey = Self.dayKey(sampleDay, calendar: calendar)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 71)
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData, Data([2]))
    }

    func testDeletedSampleBeforeCurrentWindowStartRequeriesHistoricalDay() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let sampleDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: targetStart))
        let storedStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: sampleDay))
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000738")!,
            metric: .bodyMass,
            startDate: sampleDay.addingTimeInterval(3_600),
            endDate: sampleDay.addingTimeInterval(3_600),
            value: 74
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now.addingTimeInterval(-60),
            lookbackStart: storedStart,
            replacements: [HealthSampleDaySnapshot(dayStart: sampleDay, samples: [sample], readState: .available)]
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(
                samples: [],
                deletedSampleIDs: [sample.id],
                nextAnchorData: Data([2]),
                readState: .available
            ),
            HealthSamplePage(samples: [], nextAnchorData: Data([3]), readState: .available),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].startDate, storedStart)
        XCTAssertEqual(requests[0].anchorData, Data([1]))
        XCTAssertEqual(requests[1].startDate, sampleDay)
        XCTAssertNil(requests[1].anchorData)
        let dayKey = Self.dayKey(sampleDay, calendar: calendar)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertNil(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue], .available)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            .allSatisfy { $0.sampleID != sample.id })
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData, Data([2]))
    }

    func testShortExistingSampleWindowRebaselinesIdempotentlyTo42Days() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let oldStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: now, calendar: calendar)
        )
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000733")!,
            metric: .bodyMass,
            startDate: oldStart,
            endDate: oldStart,
            value: 73
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: now,
            lookbackStart: oldStart,
            replacements: [HealthSampleDaySnapshot(dayStart: oldStart, samples: [sample], readState: .available)]
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(samples: [], nextAnchorData: Data([2]), readState: .dataUnavailableOrReadScopeUnknown)
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: now)

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        let requests = await fake.sampleRequests(for: .bodyMass)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.startDate, targetStart)
        XCTAssertNil(request.anchorData)
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.lookbackStart, targetStart)
        let indexRecords = try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
        XCTAssertFalse(indexRecords.contains { $0.sampleID == sample.id })

        let firstSnapshot = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == Self.dayKey(oldStart, calendar: calendar) }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let firstSnapshotPayload = try decoder.decode(DailyHealthSnapshot.self, from: firstSnapshot.payloadData)
        XCTAssertEqual(
            firstSnapshotPayload.healthReadStates?[HealthMetricID.bodyMass.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        XCTAssertNil(firstSnapshotPayload.healthKitSampleSummary?.aggregate(for: .bodyMass))
        let firstSnapshotHash = firstSnapshot.snapshotHash
        let repeatedResult = try await coordinator.syncAvailableData(
            using: repository,
            now: now,
            forceRebaseline: true
        )

        XCTAssertTrue(repeatedResult.completedStreams.contains(.bodyMass))
        let requestsAfterRepeat = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requestsAfterRepeat.count, 2)
        XCTAssertEqual(requestsAfterRepeat.last?.startDate, targetStart)
        XCTAssertNil(requestsAfterRepeat.last?.anchorData)
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.lookbackStart, targetStart)
        XCTAssertFalse(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
            .contains { $0.sampleID == sample.id })
        let repeatedSnapshot = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == Self.dayKey(oldStart, calendar: calendar) }))
        XCTAssertEqual(repeatedSnapshot.snapshotHash, firstSnapshotHash)
    }

    func testHealthDataWindowPolicyUses42InclusiveDaysAndRespectsAuthorizationBoundary() async throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let today = calendar.startOfDay(for: now)
        let policyStart = try XCTUnwrap(
            HealthDataWindowPolicy.analysisStart(through: today, calendar: calendar)
        )
        let authorizationStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let earlierCursor = try XCTUnwrap(calendar.date(byAdding: .day, value: -50, to: today))
        let tooRecentCursor = try XCTUnwrap(calendar.date(byAdding: .day, value: -20, to: today))

        XCTAssertEqual(
            HealthDataWindowPolicy.days(from: policyStart, through: today, calendar: calendar).count,
            42
        )
        XCTAssertEqual(
            HealthDataWindowPolicy.effectiveStart(policyStart: policyStart, authorizationStart: authorizationStart),
            authorizationStart
        )
        XCTAssertFalse(HealthDataWindowPolicy.requiresRebaseline(
            cursorStart: earlierCursor,
            policyStart: policyStart,
            authorizationStart: nil
        ))
        XCTAssertTrue(HealthDataWindowPolicy.requiresRebaseline(
            cursorStart: tooRecentCursor,
            policyStart: policyStart,
            authorizationStart: nil
        ))
        XCTAssertTrue(HealthDataWindowPolicy.requiresRebaseline(
            cursorStart: policyStart,
            policyStart: policyStart,
            authorizationStart: authorizationStart
        ))
        XCTAssertFalse(HealthDataWindowPolicy.requiresRebaseline(
            cursorStart: authorizationStart,
            policyStart: policyStart,
            authorizationStart: authorizationStart
        ))
        XCTAssertFalse(HealthDataWindowPolicy.requiresRebaseline(
            cursorStart: nil,
            policyStart: policyStart,
            authorizationStart: authorizationStart
        ))
        XCTAssertEqual(
            HealthDataWindowPolicy.firstFullyAuthorizedDay(
                for: .bodyMass,
                authorizationStart: authorizationStart,
                calendar: calendar
            ),
            authorizationStart
        )
        let partialAuthorizationStart = authorizationStart.addingTimeInterval(3_600)
        XCTAssertEqual(
            HealthDataWindowPolicy.firstFullyAuthorizedDay(
                for: .bodyMass,
                authorizationStart: partialAuthorizationStart,
                calendar: calendar
            ),
            calendar.date(byAdding: .day, value: 1, to: authorizationStart)
        )
        XCTAssertEqual(
            HealthDataWindowPolicy.firstFullyAuthorizedDay(
                for: .sleepAnalysis,
                authorizationStart: authorizationStart,
                calendar: calendar
            ),
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: authorizationStart))
        )
        let sleepBoundaryAt18 = try XCTUnwrap(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: today))
        XCTAssertEqual(
            HealthDataWindowPolicy.firstFullyAuthorizedDay(
                for: .sleepAnalysis,
                authorizationStart: sleepBoundaryAt18,
                calendar: calendar
            ),
            calendar.date(byAdding: .day, value: 1, to: today)
        )
        let lateAuthorizationStart = try XCTUnwrap(calendar.date(bySettingHour: 19, minute: 0, second: 0, of: today))
        XCTAssertEqual(
            HealthDataWindowPolicy.firstFullyAuthorizedDay(
                for: .sleepAnalysis,
                authorizationStart: lateAuthorizationStart,
                calendar: calendar
            ),
            calendar.date(byAdding: .day, value: 2, to: today)
        )
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func makeWorkoutSnapshot(id: String, startedAt: Date) throws -> WorkoutSnapshot {
        try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: id)!,
            startedAt: startedAt,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 120),
            origin: .externalHealthKit,
            dataQuality: .complete
        )
    }

    private func effortSample(id: String, at date: Date) -> HealthSampleSnapshot {
        HealthSampleSnapshot(
            id: UUID(uuidString: id)!,
            metric: .workoutEffort,
            startDate: date.addingTimeInterval(-45 * 60),
            endDate: date.addingTimeInterval(-15 * 60),
            value: 7
        )
    }

    private func seedWorkoutAndEffort(
        _ workout: WorkoutSnapshot,
        sample: HealthSampleSnapshot,
        day: Date,
        repository: HealthRepository
    ) async throws -> UUID {
        let targetStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: Date(), calendar: Calendar.current)
        )
        let verifiedCoverageDays = HealthDataWindowPolicy.days(
            from: targetStart,
            through: Calendar.current.startOfDay(for: Date()),
            calendar: Calendar.current
        )
        let verifiedReadStates: [Date: HealthReadState] = Dictionary(
            uniqueKeysWithValues: verifiedCoverageDays.map { ($0, .available) }
        )
        try await repository.applyImportedWorkouts(
            [workout],
            deletedHealthKitUUIDs: [],
            nextAnchorData: Data([1]),
            lookbackStart: targetStart,
            readStateUpdates: verifiedReadStates
        )
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.workoutEffort.rawValue,
            lastSuccessfulAt: sample.endDate,
            lookbackStart: targetStart,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [sample], readState: .available)]
        )
        return try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first {
            $0.healthKitUUID == workout.healthKitUUID
        }).id
    }

    private func seedAnchoredCursors(targetStart: Date, now: Date) throws {
        let calendar = Calendar.current
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: Data([89]),
            lastSuccessfulAt: now,
            lookbackStart: targetStart
        ))
        for (index, metric) in HealthKitSyncCoordinator.sampleStreams.sorted(by: {
            $0.rawValue < $1.rawValue
        }).enumerated() {
            let lookbackStart: Date
            if metric == .sleepAnalysis {
                let previousDay = calendar.date(byAdding: .day, value: -1, to: targetStart) ?? targetStart
                lookbackStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay) ?? previousDay
            } else {
                lookbackStart = targetStart
            }
            context.insert(HealthKitImportCursor(
                stream: metric.rawValue,
                anchorData: Data([UInt8(truncatingIfNeeded: index + 1)]),
                lastSuccessfulAt: now,
                lookbackStart: lookbackStart
            ))
        }
        try context.save()
    }

    private func insertHealthSnapshot(
        on date: Date,
        readStates: [String: HealthReadState]
    ) throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            healthReadStates: readStates,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: Self.dayKey(day, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "coordinator-health-snapshot-\(UUID().uuidString.lowercased())",
            algorithmVersion: snapshot.algorithmVersion
        ))
    }

    private func healthSnapshot(on date: Date) throws -> DailyHealthSnapshot {
        let calendar = Calendar.current
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == Self.dayKey(date, calendar: calendar) }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
    }

    func testEmptyAmbiguousWorkoutReadAdvancesCursorWithoutClaimingReadDenial() async throws {
        let fake = FakeHealthStoreClient()
        await fake.setWorkoutResponses([
            HealthChangePage(
                added: [],
                deletedObjectIDs: [],
                nextAnchorData: Data([9]),
                readState: .dataUnavailableOrReadScopeUnknown
            )
        ])
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        try await coordinator.syncAvailableData(using: HealthRepository(modelContext: context))

        let cursor = try context.fetch(FetchDescriptor<HealthKitImportCursor>())
            .first(where: { $0.stream == "workouts" })
        XCTAssertEqual(cursor?.anchorData, Data([9]))
        XCTAssertNotNil(cursor?.lastSuccessfulAt)
        XCTAssertEqual(HealthReadState.dataUnavailableOrReadScopeUnknown.rawValue, "dataUnavailableOrReadScopeUnknown")
    }

    func testOneFailedStreamDoesNotBlockOtherHealthMetrics() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: now)
        let fake = FakeHealthStoreClient()
        await fake.setAggregateResponse([
            HealthAggregateBucket(
                startDate: day,
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!,
                value: 610
            )
        ], for: .activeEnergy)
        await fake.failAggregate(for: .restingEnergy)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000711")!

        let report = try await coordinator.syncAvailableData(
            using: HealthRepository(modelContext: context),
            now: now,
            requestID: requestID
        )

        XCTAssertTrue(report.completedStreams.contains(.activeEnergy))
        let failure = try XCTUnwrap(report.failedStreams[.restingEnergy])
        XCTAssertEqual(failure.stream, .restingEnergy)
        XCTAssertEqual(failure.requestID, requestID)
        XCTAssertTrue(failure.diagnosticSafeDetail.contains("HealthKitSyncError stream=restingEnergy"))
        XCTAssertTrue(failure.diagnosticSafeDetail.contains("reason=healthKitQueryFailed"))
        XCTAssertTrue(failure.diagnosticSafeDetail.contains("requestID=\(requestID.uuidString.lowercased())"))
        XCTAssertFalse(failure.diagnosticSafeDetail.contains("fake aggregate failure"))
        let metrics = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first {
            Calendar.current.startOfDay(for: $0.date) == day
        })
        XCTAssertEqual(metrics.activeCaloriesKcal, 0)
        XCTAssertEqual(try XCTUnwrap(metrics.activeEnergyKcal), 610)
    }

    func testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let backfillStart = try XCTUnwrap(
            HealthDataWindowPolicy.initialBackfillStart(through: date, calendar: calendar)
        )
        let deletedID = UUID(uuidString: "00000000-0000-0000-0000-000000000057")!
        let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000058")!
        let existing = HealthSampleSnapshot(
            id: deletedID,
            metric: .bodyMass,
            startDate: date,
            endDate: date,
            value: 70
        )
        let replacement = HealthSampleSnapshot(
            id: replacementID,
            metric: .bodyMass,
            startDate: date.addingTimeInterval(3_600),
            endDate: date.addingTimeInterval(3_600),
            value: 72
        )
        let repository = HealthRepository(modelContext: context)
        try await repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [existing], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date,
            // The stored anchor was created with the current 42-day predicate.
            // A shorter cursor would correctly force a full rebaseline, which
            // purges this cached index before the incremental deletion arrives.
            lookbackStart: backfillStart,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [existing], readState: .available)]
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(
                samples: [],
                deletedSampleIDs: [deletedID],
                nextAnchorData: Data([2]),
                readState: .available
            ),
            HealthSamplePage(
                samples: [replacement],
                nextAnchorData: Data([3]),
                readState: .available
            ),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)

        let result = try await coordinator.syncAvailableData(using: repository, now: date)

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData, Data([2]))
        let requests = await fake.sampleRequests(for: .bodyMass)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].startDate, backfillStart)
        XCTAssertEqual(requests[0].anchorData, Data([1]))
        XCTAssertEqual(requests[1].startDate, day)
        XCTAssertNil(requests[1].anchorData)
        let dayKey = Self.dayKey(day, calendar: Calendar.current)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertNil(snapshot.healthKitSamples)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestSampleID, replacementID)
        XCTAssertEqual(snapshot.weightKilograms, 72)
        let indexes = try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
        XCTAssertEqual(indexes.map(\.sampleID), [replacementID])
    }

    func testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000059")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!
        let first = HealthSampleSnapshot(
            id: firstID,
            metric: .bodyMass,
            startDate: date,
            endDate: date.addingTimeInterval(3_600),
            value: 70,
            syncVersion: Int.min
        )
        let unversionedDuplicate = HealthSampleSnapshot(
            id: firstID,
            metric: .bodyMass,
            startDate: date,
            endDate: date.addingTimeInterval(3_600),
            value: 69
        )
        let second = HealthSampleSnapshot(
            id: secondID,
            metric: .bodyMass,
            startDate: date,
            endDate: date.addingTimeInterval(3_600),
            value: 72
        )
        let fake = FakeHealthStoreClient()
        await fake.setSampleResponses([
            HealthSamplePage(samples: [first], nextAnchorData: Data([1]), readState: .available),
            HealthSamplePage(
                samples: [unversionedDuplicate, second],
                nextAnchorData: Data([2]),
                hasMore: true,
                readState: .available
            ),
            HealthSamplePage(samples: [second, first], nextAnchorData: Data([3]), readState: .available),
        ], for: .bodyMass)
        let coordinator = HealthKitSyncCoordinator(healthStore: fake, observer: fake)
        let repository = HealthRepository(modelContext: context)

        let firstResult = try await coordinator.syncAvailableData(using: repository, now: date)

        XCTAssertTrue(firstResult.completedStreams.contains(.bodyMass))
        let dayKey = Self.dayKey(date, calendar: Calendar.current)
        let firstRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let firstSnapshot = try decoder.decode(DailyHealthSnapshot.self, from: firstRecord.payloadData)
        XCTAssertEqual(firstSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.sampleCount, 2)
        XCTAssertEqual(firstSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.averageValue, 71)
        XCTAssertEqual(firstSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestSampleID, secondID)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthKitSampleIndexRecord>()), 2)
        let firstHash = firstRecord.snapshotHash

        await fake.setSampleResponses([
            HealthSamplePage(samples: [first], nextAnchorData: Data([4]), readState: .available),
            HealthSamplePage(
                samples: [second, first],
                nextAnchorData: Data([5]),
                hasMore: true,
                readState: .available
            ),
            HealthSamplePage(samples: [unversionedDuplicate, second], nextAnchorData: Data([6]), readState: .available),
        ], for: .bodyMass)

        let secondResult = try await coordinator.syncAvailableData(using: repository, now: date.addingTimeInterval(60))

        XCTAssertTrue(secondResult.completedStreams.contains(.bodyMass))
        let persistedRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }))
        let persistedSnapshot = try decoder.decode(DailyHealthSnapshot.self, from: persistedRecord.payloadData)
        XCTAssertEqual(persistedSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.sampleCount, 2)
        XCTAssertEqual(persistedSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestSampleID, secondID)
        XCTAssertEqual(persistedRecord.snapshotHash, firstHash)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).map(\.sampleID).sorted {
                $0.uuidString < $1.uuidString
            },
            [firstID, secondID].sorted { $0.uuidString < $1.uuidString }
        )
        XCTAssertEqual(try repository.cursor(for: HealthMetricID.bodyMass.rawValue)?.anchorData, Data([4]))
        XCTAssertEqual(firstSnapshot.dayStart, Calendar.current.startOfDay(for: date))
    }
}

private enum CoordinatorInjectedSaveFailure: Error {
    case failed
}
