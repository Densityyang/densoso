import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ConfirmationCoordinatorTests: XCTestCase {
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
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
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
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
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
