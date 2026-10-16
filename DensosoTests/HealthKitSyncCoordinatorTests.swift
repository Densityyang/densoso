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
                WeightRecord.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
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
            _ = try? intelligence.refresh(asOf: date)
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

        let report = try await coordinator.syncAvailableData(using: HealthRepository(modelContext: context), now: now)

        XCTAssertTrue(report.completedStreams.contains(.activeEnergy))
        XCTAssertNotNil(report.failedStreams[.restingEnergy])
        let metrics = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metrics.activeCaloriesKcal, 610)
    }
}
