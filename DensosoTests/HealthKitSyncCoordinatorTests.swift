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
        let date = Date(timeIntervalSince1970: 1_700_000_000)
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
        coordinator.onObserverSyncCompleted = {
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

        let metrics = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metrics.activeCaloriesKcal, 640)
        XCTAssertEqual(metrics.workoutCount, 1)
        XCTAssertEqual(metrics.totalExpenditureKcal, 0)
        XCTAssertEqual(metrics.energyQuality, "unavailable")
        XCTAssertTrue(report.failedStreams.isEmpty)
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
        let metrics = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metrics.activeCaloriesKcal, 610)
    }

    func testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
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
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [existing], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date,
            lookbackStart: day,
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
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
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
        let firstRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
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
        let persistedRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
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
