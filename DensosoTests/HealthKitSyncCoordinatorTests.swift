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

    func testHealthContextExportGateStaysClosedWhenForegroundPurgeFails() async throws {
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
        let failingRepository = HealthRepository(modelContext: context, willSave: {
            throw NSError(domain: "HealthSnapshotPurge", code: 1)
        })

        do {
            try await coordinator.prepareForegroundSnapshotRebuild(using: failingRepository, now: now)
            XCTFail("Expected the injected save failure")
        } catch {}
        XCTAssertFalse(gate.isOpen)
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
                lookbackStart: day
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

        XCTAssertTrue(result.completedStreams.contains(.bodyMass))
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
