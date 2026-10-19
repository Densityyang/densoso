import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ConfirmationCoordinatorTests: XCTestCase {
    func testConfirmationErrorsDistinguishRetryableWatchReplayFromTerminalFailures() {
        XCTAssertTrue(ConfirmationError.alreadyCommitting.isRetryable)
        XCTAssertTrue(ConfirmationError.persistenceReadOnly(diagnosticID: "recovery").isRetryable)
        XCTAssertTrue(ConfirmationError.commitFailed(retryable: true).isRetryable)

        XCTAssertFalse(ConfirmationError.notFound.isRetryable)
        XCTAssertFalse(ConfirmationError.expired.isRetryable)
        XCTAssertFalse(ConfirmationError.rejected.isRetryable)
        XCTAssertFalse(ConfirmationError.payloadCorrupt.isRetryable)
        XCTAssertFalse(ConfirmationError.unsupportedAction.isRetryable)
        XCTAssertFalse(ConfirmationError.invariantViolation("terminal").isRetryable)
        XCTAssertFalse(ConfirmationError.commitFailed(retryable: false).isRetryable)
    }

    func testConcurrentStageAndConfirmWriteOneLogicalTransaction() async throws {
        let harness = try Harness()
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let payload = try Self.sampleMeal()

        async let firstStage = harness.coordinator.stage(payload: payload, clientRequestID: requestID)
        async let secondStage = harness.coordinator.stage(payload: payload, clientRequestID: requestID)
        let staged = try await [firstStage, secondStage]
        XCTAssertEqual(Set(staged.map(\.id)).count, 1)

        async let firstConfirm = harness.coordinator.confirm(id: staged[0].id)
        async let secondConfirm = harness.coordinator.confirm(id: staged[0].id)
        let receipts = try await [firstConfirm, secondConfirm]
        XCTAssertEqual(Set(receipts.map(\.id)).count, 1)

        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyReport>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 1)
    }

    func testMealConfirmationPreservesMeasuredHealthKitEnergyProjection() async throws {
        let harness = try Harness()
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
        let data = try encoder.encode(snapshot)
        let context = ModelContext(harness.container)
        let futureDay = Calendar.current.date(byAdding: .day, value: 20, to: day)!
        let futureComponents = Calendar.current.dateComponents([.year, .month, .day], from: futureDay)
        let futureDayKey = String(format: "%04d-%02d-%02d", futureComponents.year ?? 0, futureComponents.month ?? 0, futureComponents.day ?? 0)
        let futureSnapshot = DailyHealthSnapshot(
            dayStart: futureDay,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            activeEnergyKcal: 999,
            healthKitSamples: [HealthSampleSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                metric: .bodyMass,
                startDate: futureDay,
                endDate: futureDay,
                value: 120
            )],
            healthReadStates: [HealthMetricID.activeEnergy.rawValue: .available],
            algorithmVersion: "future-fixture"
        )
        let birthDate = Date(timeIntervalSince1970: 315_532_800)
        context.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: day.addingTimeInterval(-365 * 86_400),
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 70,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        context.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: futureDay,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 85,
            activityLevel: "active",
            source: "userEdited"
        ))
        context.insert(WeightRecord(
            sourceActionKey: "confirmation-future-weight",
            measuredAt: day.addingTimeInterval(2 * 86_400),
            kilograms: 65
        ))
        context.insert(WeightRecord(
            sourceActionKey: "confirmation-distant-weight",
            measuredAt: day.addingTimeInterval(50 * 86_400),
            kilograms: 95
        ))
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey,
            timezoneID: Calendar.current.timeZone.identifier,
            payloadData: data,
            snapshotHash: "fixture",
            algorithmVersion: "v3"
        ))
        context.insert(DailyHealthSnapshotRecord(
            dayKey: futureDayKey,
            timezoneID: Calendar.current.timeZone.identifier,
            payloadData: try encoder.encode(futureSnapshot),
            snapshotHash: "fixture-future",
            algorithmVersion: futureSnapshot.algorithmVersion
        ))
        try context.save()

        let action = try await harness.coordinator.stage(payload: Self.sampleMeal(), clientRequestID: UUID())
        _ = try await harness.coordinator.confirm(id: action.id)

        let resultContext = ModelContext(harness.container)
        let metrics = try XCTUnwrap(resultContext.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metrics.activeCaloriesKcal, 640)
        XCTAssertEqual(metrics.bmrKcal, 1_410)
        XCTAssertEqual(metrics.totalExpenditureKcal, 2_050)
        XCTAssertEqual(metrics.weightKg, 70)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let savedSnapshot = try decoder.decode(
            DailyHealthSnapshot.self,
            from: XCTUnwrap(resultContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>(
                predicate: #Predicate { $0.dayKey == dayKey }
            )).first).payloadData
        )
        XCTAssertEqual(savedSnapshot.activeEnergyKcal, 640)
        XCTAssertEqual(savedSnapshot.restingEnergyKcal, 1_410)
    }

    func testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision() async throws {
        let harness = try Harness()
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = calendar.startOfDay(for: date)
        let birthDate = Date(timeIntervalSince1970: 315_532_800)
        let sharedCreatedAt = date.addingTimeInterval(-60)
        let context = ModelContext(harness.container)
        context.insert(ProfileRevisionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000400")!,
            effectiveFrom: calendar.date(byAdding: .day, value: -10, to: day)!,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 70,
            activityLevel: "moderate",
            source: "userEdited",
            createdAt: sharedCreatedAt
        ))
        context.insert(ProfileRevisionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            effectiveFrom: day,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 80,
            activityLevel: "moderate",
            source: "userEdited",
            createdAt: sharedCreatedAt
        ))
        context.insert(ProfileRevisionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
            effectiveFrom: day,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 85,
            activityLevel: "active",
            source: "userEdited",
            createdAt: sharedCreatedAt
        ))
        context.insert(ProfileRevisionRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
            effectiveFrom: calendar.date(byAdding: .day, value: 1, to: day)!,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 95,
            activityLevel: "active",
            source: "userEdited",
            createdAt: sharedCreatedAt
        ))
        try context.save()

        try DailyMetricsProjector.reproject(on: day, in: context)
        try context.save()
        let standaloneMetric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(standaloneMetric.weightKg, 85)

        let action = try await harness.coordinator.stage(payload: Self.sampleMeal(), clientRequestID: UUID())
        _ = try await harness.coordinator.confirm(id: action.id)

        let confirmationContext = ModelContext(harness.container)
        let confirmationMetric = try XCTUnwrap(
            confirmationContext.fetch(FetchDescriptor<DailyMetrics>()).first
        )
        XCTAssertEqual(confirmationMetric.weightKg, standaloneMetric.weightKg)
        XCTAssertEqual(confirmationMetric.weightKg, 85)
    }

    func testConfirmationWeeklyReportUsesOnlyMetricsInsideItsWeek() async throws {
        let harness = try Harness()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let interval = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: date))
        let actionDay = calendar.startOfDay(for: date)
        let otherDayInWeek = try XCTUnwrap((0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }.first { !calendar.isDate($0, inSameDayAs: actionDay) })
        let context = ModelContext(harness.container)
        context.insert(DailyMetrics(date: otherDayInWeek, deficitKcal: 120, mealCount: 2))
        context.insert(DailyMetrics(
            date: interval.start.addingTimeInterval(-60),
            deficitKcal: 10_000,
            mealCount: 10
        ))
        context.insert(DailyMetrics(date: interval.end, deficitKcal: 20_000, mealCount: 20))
        try context.save()

        let action = try await harness.coordinator.stage(payload: Self.sampleMeal(), clientRequestID: UUID())
        _ = try await harness.coordinator.confirm(id: action.id)

        let verificationContext = ModelContext(harness.container)
        let weeklyMetrics = try verificationContext.fetch(FetchDescriptor<DailyMetrics>()).filter {
            $0.date >= interval.start && $0.date < interval.end
        }
        let weekStart = calendar.startOfDay(for: interval.start)
        let reportPredicate = #Predicate<WeeklyReport> { $0.weekStartDate == weekStart }
        let report = try XCTUnwrap(verificationContext.fetch(
            FetchDescriptor<WeeklyReport>(predicate: reportPredicate)
        ).first)
        XCTAssertEqual(report.totalDeficitKcal, weeklyMetrics.reduce(0) { $0 + $1.deficitKcal })
        XCTAssertEqual(report.mealsCount, weeklyMetrics.reduce(0) { $0 + $1.mealCount })
        XCTAssertFalse(weeklyMetrics.contains { $0.deficitKcal == 10_000 || $0.deficitKcal == 20_000 })
    }

    func testConfirmedWorkoutPlanCreatesRetryableScheduleIntentButNoWorkoutOrHealthOutbox() async throws {
        let harness = try Harness()
        let draft = WorkoutPlanDraft(
            name: "午后步行",
            activity: .walking,
            location: .outdoor,
            goal: .distanceMeters(2_000),
            scheduledAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let action = try await harness.coordinator.stage(
            payload: .workoutPlan(draft),
            clientRequestID: UUID()
        )

        let first = try await harness.coordinator.confirm(id: action.id)
        let replay = try await harness.coordinator.confirm(id: action.id)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.actionType, .workoutPlan)
        XCTAssertEqual(first.localRecordID, action.id)
        XCTAssertEqual(first.outboxIDs, [])
        XCTAssertEqual(first.healthSyncState, .notApplicable)

        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 0)
        let events = try context.fetch(FetchDescriptor<ScheduleEvent>())
        let entry = try XCTUnwrap(events.compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }.first)
        XCTAssertEqual(entry.actionID, action.id)
        XCTAssertEqual(entry.idempotencyKey, action.idempotencyKey)
        XCTAssertEqual(entry.draft, draft)
        XCTAssertEqual(entry.state, .queued)
    }

    func testRejectAndExpiryNeverWriteHealthRecords() async throws {
        let rejectedHarness = try Harness()
        let rejected = try await rejectedHarness.coordinator.stage(
            payload: Self.sampleWeight(),
            clientRequestID: UUID()
        )
        try await rejectedHarness.coordinator.reject(id: rejected.id)
        await XCTAssertThrowsErrorAsync(try await rejectedHarness.coordinator.confirm(id: rejected.id)) { error in
            XCTAssertEqual(error as? ConfirmationError, .rejected)
        }
        try assertNoCommittedWrites(in: rejectedHarness.container)

        let expiredHarness = try Harness(timeToLive: 0)
        let expired = try await expiredHarness.coordinator.stage(
            payload: Self.sampleWeight(),
            clientRequestID: UUID()
        )
        await XCTAssertThrowsErrorAsync(try await expiredHarness.coordinator.confirm(id: expired.id)) { error in
            XCTAssertEqual(error as? ConfirmationError, .expired)
        }
        let expiredForReject = try await expiredHarness.coordinator.stage(
            payload: Self.sampleWeight(),
            clientRequestID: UUID()
        )
        await XCTAssertThrowsErrorAsync(
            try await expiredHarness.coordinator.reject(id: expiredForReject.id)
        ) { error in
            XCTAssertEqual(error as? ConfirmationError, .expired)
        }
        try assertNoCommittedWrites(in: expiredHarness.container)
    }

    func testTransactionFaultRollsBackThenRecoveryRestoresPending() async throws {
        let harness = try Harness()
        let action = try await harness.coordinator.stage(payload: try Self.sampleMeal(), clientRequestID: UUID())
        await harness.repository.setFaultPoint(.afterOutbox)

        await XCTAssertThrowsErrorAsync(try await harness.coordinator.confirm(id: action.id)) { error in
            XCTAssertEqual(error as? ConfirmationInjectedFailure, .fault(.afterOutbox))
        }

        let failedContext = ModelContext(harness.container)
        XCTAssertEqual(try failedContext.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try failedContext.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 0)
        XCTAssertEqual(try failedContext.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(try failedContext.fetchCount(FetchDescriptor<DailyMetrics>()), 0)
        XCTAssertEqual(try failedContext.fetchCount(FetchDescriptor<WeeklyReport>()), 0)
        XCTAssertEqual(try failedContext.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 0)

        await harness.repository.setFaultPoint(nil)
        try await harness.coordinator.recoverInterruptedCommits()
        let recovered = try await harness.coordinator.activeActions()
        XCTAssertEqual(recovered.first?.state, .pending)
        _ = try await harness.coordinator.confirm(id: action.id)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 1)
    }

    func testCrashAfterCommitReturnsExistingReceiptWithoutDuplicate() async throws {
        let location = try TemporaryConfirmationStore()
        defer { location.remove() }
        var container: ModelContainer? = try makeDiskContainer(at: location.storeURL)
        var repository: SwiftDataConfirmationRepository? = SwiftDataConfirmationRepository(modelContainer: container!)
        var coordinator: ConfirmationCoordinator? = makeCoordinator(repository: repository!)
        let action = try await coordinator!.stage(payload: Self.sampleWeight(), clientRequestID: UUID())
        await repository!.setFaultPoint(.afterTransactionCommitted)

        do {
            _ = try await coordinator!.confirm(id: action.id)
            XCTFail("Expected an injected post-commit failure")
        } catch {
            XCTAssertEqual(error as? ConfirmationInjectedFailure, .fault(.afterTransactionCommitted))
        }
        coordinator = nil
        repository = nil
        container = nil
        await Task.yield()

        container = try makeDiskContainer(at: location.storeURL)
        repository = SwiftDataConfirmationRepository(modelContainer: container!)
        coordinator = makeCoordinator(repository: repository!)
        let receipt = try await coordinator!.confirm(id: action.id)

        let context = ModelContext(container!)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeightRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyReport>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 1)
        let snapshotRecord = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        XCTAssertEqual(
            try decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData).weightKilograms,
            62.5
        )
        XCTAssertEqual(receipt.actionID, action.id)
    }

    func testSendingOutboxReturnsToRetryableAfterRestart() async throws {
        let location = try TemporaryConfirmationStore()
        defer { location.remove() }
        var container: ModelContainer? = try makeDiskContainer(at: location.storeURL)
        var repository: SwiftDataConfirmationRepository? = SwiftDataConfirmationRepository(modelContainer: container!)
        var coordinator: ConfirmationCoordinator? = makeCoordinator(repository: repository!)
        let action = try await coordinator!.stage(payload: Self.sampleWeight(), clientRequestID: UUID())
        _ = try await coordinator!.confirm(id: action.id)
        do {
            let context = ModelContext(container!)
            let entry = try XCTUnwrap(context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).first)
            entry.state = HealthSyncState.sending.rawValue
            entry.attemptCount = 2
            try context.save()
        }
        coordinator = nil
        repository = nil
        container = nil
        await Task.yield()

        container = try makeDiskContainer(at: location.storeURL)
        repository = SwiftDataConfirmationRepository(modelContainer: container!)
        coordinator = makeCoordinator(repository: repository!)
        try await coordinator!.recoverInterruptedCommits()

        let recovered = try XCTUnwrap(ModelContext(container!).fetch(FetchDescriptor<HealthSyncOutboxEntry>()).first)
        XCTAssertEqual(recovered.state, HealthSyncState.retryable.rawValue)
        XCTAssertEqual(recovered.attemptCount, 2)
        XCTAssertNotNil(recovered.nextAttemptAt)
    }

    func testPendingActionSurvivesRepositoryRecreation() async throws {
        let location = try TemporaryConfirmationStore()
        defer { location.remove() }
        var container: ModelContainer? = try makeDiskContainer(at: location.storeURL)
        var repository: SwiftDataConfirmationRepository? = SwiftDataConfirmationRepository(modelContainer: container!)
        var coordinator: ConfirmationCoordinator? = makeCoordinator(repository: repository!)
        let action = try await coordinator!.stage(
            payload: Self.sampleWeight(),
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000150")!
        )
        coordinator = nil
        repository = nil
        container = nil
        await Task.yield()

        container = try makeDiskContainer(at: location.storeURL)
        repository = SwiftDataConfirmationRepository(modelContainer: container!)
        coordinator = makeCoordinator(repository: repository!)

        let restored = try await coordinator!.activeActions()

        XCTAssertEqual(restored.map(\.id), [action.id])
        XCTAssertEqual(restored.first?.state, .pending)
    }

    private static func sampleMeal() throws -> ActionPayload {
        let energy = try EstimateRange(low: 380, likely: 420, high: 500)
        let macros = try EstimateRange.point(20)
        let dish = MealDishDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            name: "fixture meal",
            nutrients: NutrientEstimate(
                energyKcal: energy,
                proteinGrams: macros,
                fatGrams: macros,
                carbohydrateGrams: macros
            ),
            evidence: [EvidenceSnapshot(grade: .userReported, summary: "fixture", confidence: 0.8)],
            algorithmVersion: "v3"
        )
        return .meal(
            MealDraft(
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                mealType: "lunch",
                dishes: [dish]
            )
        )
    }

    private static func sampleWeight() -> ActionPayload {
        .weight(
            WeightDraft(
                measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                kilograms: 62.5
            )
        )
    }

    private func assertNoCommittedWrites(in container: ModelContainer) throws {
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeightRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyReport>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 0)
    }

    private func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration("Gate02Confirmation", schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeCoordinator(repository: SwiftDataConfirmationRepository) -> ConfirmationCoordinator {
        ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

private struct Harness {
    let container: ModelContainer
    let repository: SwiftDataConfirmationRepository
    let coordinator: ConfirmationCoordinator

    init(timeToLive: TimeInterval = 24 * 60 * 60) throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        repository = SwiftDataConfirmationRepository(modelContainer: container)
        coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: .writable),
            timeToLive: timeToLive,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}

private struct TemporaryConfirmationStore {
    let directoryURL: URL
    let storeURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-confirmation-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        storeURL = directoryURL.appendingPathComponent("default.store")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error")
    } catch {
        errorHandler(error)
    }
}
