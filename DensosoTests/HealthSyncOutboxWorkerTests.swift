import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class HealthSyncOutboxWorkerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var previousConnectionPreference = false

    override func setUpWithError() throws {
        previousConnectionPreference = HealthKitConnectionPreference.hasRequestedAuthorization
        container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self,
                DailyHealthSnapshotRecord.self, WeightRecord.self, ProfileRevisionRecord.self, HealthSyncOutboxEntry.self,
                HealthKitImportCursor.self, CommittedActionReceiptRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        HealthKitConnectionPreference.hasRequestedAuthorization = previousConnectionPreference
        context = nil
        container = nil
        super.tearDown()
    }

    func testConfirmedMealWritesOnlyKnownNutritionAndPersistsReceipt() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let meal = MealRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 520,
            proteinG: 32,
            fatG: 18,
            carbsG: 61,
            energyLikelyKcal: 519.5,
            proteinLikelyG: 32,
            fatLikelyG: nil,
            carbsLikelyG: 61
        )
        let entry = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: meal.id,
            syncIdentifier: "densoso.meal.\(meal.id.uuidString.lowercased())"
        )
        context.insert(meal)
        context.insert(entry)
        try context.save()

        let fake = FakeHealthStoreClient()
        let worker = HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
        await worker.processPending(in: context)

        XCTAssertEqual(entry.state, "succeeded")
        XCTAssertEqual(entry.attemptCount, 1)
        let successfulWrites = await fake.successfulWritesSnapshot()
        let command = try XCTUnwrap(successfulWrites.first)
        XCTAssertEqual(command.syncIdentifier, entry.syncIdentifier)
        XCTAssertEqual(command.syncVersion, 1)
        guard case .nutrition(let nutrition) = command.payload else {
            return XCTFail("Expected a meal nutrition write")
        }
        XCTAssertEqual(nutrition.energyKilocalories, 519.5)
        XCTAssertEqual(nutrition.proteinGrams, 32)
        XCTAssertNil(nutrition.fatGrams)
        XCTAssertEqual(nutrition.carbohydrateGrams, 61)
        let savedReceipt = try JSONDecoder().decode(HealthWriteReceipt.self, from: entry.payloadData)
        XCTAssertEqual(savedReceipt.recordID, meal.id)
        XCTAssertEqual(savedReceipt.metrics, [.dietaryEnergy, .dietaryProtein, .dietaryCarbohydrates])
    }

    func testRetryReusesStableSyncIdentifierAndVersion() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let weight = WeightRecord(
            sourceActionKey: "confirmed-weight-action",
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            kilograms: 68.4,
            source: "manual"
        )
        let entry = HealthSyncOutboxEntry(
            operation: "upsertWeight",
            recordID: weight.id,
            syncIdentifier: "densoso.weight.\(weight.id.uuidString.lowercased())"
        )
        context.insert(weight)
        context.insert(entry)
        try context.save()

        let fake = FakeHealthStoreClient()
        await fake.failNextWrites(1)
        let worker = HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
        let firstAttempt = Date(timeIntervalSince1970: 1_700_000_000)
        await worker.processPending(in: context, now: firstAttempt)
        XCTAssertEqual(entry.state, "retryable")

        await worker.processPending(in: context, now: firstAttempt.addingTimeInterval(86_400))
        XCTAssertEqual(entry.state, "succeeded")
        let attempts = await fake.attemptedWritesSnapshot()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0].syncIdentifier, attempts[1].syncIdentifier)
        XCTAssertEqual(attempts[0].syncVersion, attempts[1].syncVersion)
        guard case .confirmedWeight(let kilograms) = attempts[1].payload else {
            return XCTFail("Expected a confirmed weight write")
        }
        XCTAssertEqual(kilograms, 68.4)
    }

    func testNewerMealVersionSupersedesAnUnsentOutboxWrite() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let repository = HealthRepository(modelContext: context)
        let meal = MealRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 420,
            energyLikelyKcal: 420,
            proteinLikelyG: 20
        )
        try repository.insert(meal)
        meal.totalCaloriesKcal = 580
        meal.energyLikelyKcal = 580
        meal.proteinLikelyG = 31
        try repository.update(meal)

        let entries = try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>())
            .sorted { $0.syncVersion < $1.syncVersion }
        XCTAssertEqual(entries.map(\.syncVersion), [1, 2])
        XCTAssertEqual(entries[0].syncIdentifier, entries[1].syncIdentifier)

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        XCTAssertEqual(entries[0].state, "succeeded")
        XCTAssertEqual(entries[1].state, "succeeded")
        let successfulWrites = await fake.successfulWritesSnapshot()
        XCTAssertEqual(successfulWrites.count, 1)
        let write = try XCTUnwrap(successfulWrites.first)
        XCTAssertEqual(write.syncVersion, 2)
        guard case .nutrition(let nutrition) = write.payload else {
            return XCTFail("Expected the newest meal payload to be written")
        }
        XCTAssertEqual(nutrition.energyKilocalories, 580)
        XCTAssertEqual(nutrition.proteinGrams, 31)
    }

    func testSupersessionCheckPagesPast64SameRecordRows() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let syncIdentifier = "densoso.meal.\(recordID.uuidString.lowercased())"
        let older = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: recordID,
            idempotencyKey: "outbox-old-version",
            state: "pending",
            syncIdentifier: syncIdentifier,
            syncVersion: 1
        )
        older.createdAt = now
        context.insert(older)

        let futureRetryAt = now.addingTimeInterval(3_600)
        for index in 0..<HealthSyncOutboxWorker.outboxBatchSize {
            let decoy = HealthSyncOutboxEntry(
                operation: "unrelated-\(index)",
                recordID: recordID,
                idempotencyKey: "outbox-decoy-\(index)",
                state: "retryable",
                nextAttemptAt: futureRetryAt,
                syncIdentifier: "unrelated-\(index)",
                syncVersion: 20
            )
            decoy.createdAt = now.addingTimeInterval(TimeInterval(index + 1))
            context.insert(decoy)
        }

        let newer = HealthSyncOutboxEntry(
            operation: "deleteMeal",
            recordID: recordID,
            idempotencyKey: "outbox-newer-version",
            state: "retryable",
            nextAttemptAt: futureRetryAt,
            syncIdentifier: syncIdentifier,
            syncVersion: 2
        )
        newer.createdAt = now.addingTimeInterval(HealthSyncOutboxWorker.outboxBatchSize + 1)
        context.insert(newer)
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context, now: now)

        XCTAssertEqual(older.state, "succeeded")
        XCTAssertEqual(older.attemptCount, 1)
        XCTAssertEqual(newer.state, "retryable")
        let successfulWrites = await fake.successfulWritesSnapshot()
        XCTAssertTrue(successfulWrites.isEmpty)
    }

    func testNoWriteIsAttemptedBeforeTheUserStartsHealthKitAuthorization() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = false
        let meal = MealRecord(date: Date(), totalCaloriesKcal: 300)
        let entry = HealthSyncOutboxEntry(operation: "upsertMeal", recordID: meal.id)
        context.insert(meal)
        context.insert(entry)
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        XCTAssertEqual(entry.state, "pending")
        let attemptedWrites = await fake.attemptedWritesSnapshot()
        XCTAssertTrue(attemptedWrites.isEmpty)
    }

    func testInterruptedSendingEntryIsRecoveredAndRetried() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let meal = MealRecord(date: Date(timeIntervalSince1970: 1_700_000_000), totalCaloriesKcal: 350)
        let entry = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: meal.id,
            state: "sending",
            attemptCount: 1,
            syncIdentifier: "densoso.meal.\(meal.id.uuidString.lowercased())"
        )
        context.insert(meal)
        context.insert(entry)
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        XCTAssertEqual(entry.state, "succeeded")
        XCTAssertEqual(entry.attemptCount, 2)
        let attemptedWrites = await fake.attemptedWritesSnapshot()
        XCTAssertEqual(attemptedWrites.count, 1)
    }

    func testPendingQuerySkipsFutureRetriesAndTerminalRows() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dueMeal = MealRecord(date: now, totalCaloriesKcal: 300)
        let futureMeal = MealRecord(date: now, totalCaloriesKcal: 450)
        let dueEntry = HealthSyncOutboxEntry(operation: "upsertMeal", recordID: dueMeal.id)
        let futureEntry = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: futureMeal.id,
            state: "retryable",
            attemptCount: 3,
            nextAttemptAt: now.addingTimeInterval(3_600)
        )
        let terminalEntry = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: UUID(),
            state: "terminal",
            attemptCount: 8
        )
        context.insert(dueMeal)
        context.insert(futureMeal)
        context.insert(dueEntry)
        context.insert(futureEntry)
        context.insert(terminalEntry)
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context, now: now)

        XCTAssertEqual(dueEntry.state, "succeeded")
        XCTAssertEqual(dueEntry.attemptCount, 1)
        XCTAssertEqual(futureEntry.state, "retryable")
        XCTAssertEqual(futureEntry.attemptCount, 3)
        XCTAssertEqual(terminalEntry.state, "terminal")
        let successfulWrites = await fake.successfulWritesSnapshot()
        XCTAssertEqual(successfulWrites.count, 1)
        XCTAssertEqual(successfulWrites.first?.recordID, dueMeal.id)
    }

    func testInterruptedOutboxRecoveryAndProcessingPagePastBoundedBatch() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entryCount = HealthSyncOutboxWorker.outboxBatchSize + 1
        var entries: [HealthSyncOutboxEntry] = []
        for _ in 0..<entryCount {
            let recordID = UUID()
            let entry = HealthSyncOutboxEntry(operation: "deleteWeight", recordID: recordID)
            entry.createdAt = now
            entry.idempotencyKey = "outbox-batch-\(recordID.uuidString.lowercased())"
            entry.state = "sending"
            context.insert(entry)
            entries.append(entry)
        }
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context, now: now)

        XCTAssertTrue(entries.allSatisfy { $0.state == "succeeded" && $0.attemptCount == 1 })
        let deletedReceipts = await fake.deletedReceiptsSnapshot()
        XCTAssertEqual(deletedReceipts.count, entryCount)
    }

    func testMealDeletionUsesOnlyItsStableApplicationSyncIdentifier() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let mealID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let syncIdentifier = "densoso.meal.\(mealID.uuidString.lowercased())"
        let entry = HealthSyncOutboxEntry(
            operation: "deleteMeal",
            recordID: mealID,
            syncIdentifier: syncIdentifier
        )
        context.insert(entry)
        try context.save()

        let fake = FakeHealthStoreClient()
        let worker = HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
        await worker.processPending(in: context)

        XCTAssertEqual(entry.state, "succeeded")
        let deletedReceipts = await fake.deletedReceiptsSnapshot()
        let receipt = try XCTUnwrap(deletedReceipts.first)
        XCTAssertEqual(receipt.syncIdentifier, syncIdentifier)
        XCTAssertEqual(receipt.metrics, [.dietaryEnergy, .dietaryProtein, .dietaryFat, .dietaryCarbohydrates])
    }

    func testWeightUpdatesAndDeleteConvergeToTheNewestVersion() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let repository = HealthRepository(modelContext: context)
        let weight = WeightRecord(
            sourceActionKey: "confirmed-weight-action",
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            kilograms: 68.4,
            source: "manual"
        )
        context.insert(weight)
        try context.save()
        try repository.update(weight)
        weight.kilograms = 67.8
        try repository.update(weight)
        try repository.delete(weight)

        let entries = try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>())
            .sorted { $0.syncVersion < $1.syncVersion }
        XCTAssertEqual(entries.map(\.syncVersion), [1, 2, 3])
        XCTAssertEqual(Set(entries.map(\.syncIdentifier)).count, 1)

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        XCTAssertTrue(entries.allSatisfy { $0.state == "succeeded" })
        let writes = await fake.successfulWritesSnapshot()
        let deletes = await fake.deletedReceiptsSnapshot()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(deletes.first?.syncVersion, 3)
        XCTAssertEqual(deletes.first?.metrics, [.bodyMass])
    }
}

extension FakeHealthStoreClient {
    func attemptedWritesSnapshot() -> [HealthWriteCommand] { attemptedWrites }
    func successfulWritesSnapshot() -> [HealthWriteCommand] { successfulWrites }
    func deletedReceiptsSnapshot() -> [HealthWriteReceipt] { deletedReceipts }
}
