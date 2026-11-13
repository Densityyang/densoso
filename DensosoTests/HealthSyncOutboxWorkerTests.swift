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

        let persistedEntry = try XCTUnwrap(persistedOutboxSnapshots()[entry.id])
        XCTAssertEqual(persistedEntry.state, "succeeded")
        XCTAssertEqual(persistedEntry.attemptCount, 1)
        let successfulWrites = await fake.successfulWritesSnapshot()
        let command = try XCTUnwrap(successfulWrites.first)
        XCTAssertEqual(command.syncIdentifier, persistedEntry.syncIdentifier)
        XCTAssertEqual(command.syncVersion, 1)
        guard case .nutrition(let nutrition) = command.payload else {
            return XCTFail("Expected a meal nutrition write")
        }
        XCTAssertEqual(nutrition.energyKilocalories, 519.5)
        XCTAssertEqual(nutrition.proteinGrams, 32)
        XCTAssertNil(nutrition.fatGrams)
        XCTAssertEqual(nutrition.carbohydrateGrams, 61)
        let savedReceipt = try JSONDecoder().decode(HealthWriteReceipt.self, from: persistedEntry.payloadData)
        XCTAssertEqual(savedReceipt.recordID, meal.id)
        XCTAssertEqual(savedReceipt.metrics, [.dietaryEnergy, .dietaryProtein, .dietaryCarbohydrates])
    }

    func testLegacyAndUnresolvedZeroEnergyMealsBecomeTerminalWithoutHealthKitWrites() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let legacyEvidence = try JSONEncoder().encode([
            EvidenceSnapshot(grade: .legacyPointEstimate, sourceID: "legacy-v2-default-zero-energy", summary: "Legacy default")
        ])
        let unresolvedEvidence = try JSONEncoder().encode([
            EvidenceSnapshot(grade: .unresolved, sourceID: "migration", summary: "Unknown energy")
        ])
        let legacyMeal = MealRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000861")!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 0,
            energyLikelyKcal: 0,
            evidenceData: legacyEvidence
        )
        let unresolvedMeal = MealRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000862")!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 0,
            energyLikelyKcal: 0,
            evidenceData: unresolvedEvidence
        )
        let entries = [
            HealthSyncOutboxEntry(operation: "upsertMeal", recordID: legacyMeal.id),
            HealthSyncOutboxEntry(operation: "upsertMeal", recordID: unresolvedMeal.id),
        ]
        context.insert(legacyMeal)
        context.insert(unresolvedMeal)
        for entry in entries { context.insert(entry) }
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        let persisted = try persistedOutboxSnapshots()
        XCTAssertEqual(entries.compactMap { persisted[$0.id]?.state }, ["terminal", "terminal"])
        let attemptedWrites = await fake.attemptedWritesSnapshot()
        XCTAssertTrue(attemptedWrites.isEmpty)
    }

    func testEvidenceBackedZeroEnergyMealCanWriteExplicitZeroToHealthKit() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let evidenceData = try JSONEncoder().encode([
            EvidenceSnapshot(grade: .measured, sourceID: "verified-measurement", summary: "Explicit zero energy")
        ])
        let meal = MealRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000863")!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 0,
            energyLikelyKcal: 0,
            evidenceData: evidenceData
        )
        let entry = HealthSyncOutboxEntry(operation: "upsertMeal", recordID: meal.id)
        context.insert(meal)
        context.insert(entry)
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        XCTAssertEqual(try XCTUnwrap(persistedOutboxSnapshots()[entry.id]).state, "succeeded")
        let writes = await fake.successfulWritesSnapshot()
        let command = try XCTUnwrap(writes.first)
        guard case .nutrition(let nutrition) = command.payload else {
            return XCTFail("Expected a meal nutrition write")
        }
        XCTAssertEqual(nutrition.energyKilocalories, 0)
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
        let firstPersistedEntry = try XCTUnwrap(persistedOutboxSnapshots()[entry.id])
        XCTAssertEqual(firstPersistedEntry.state, "retryable")
        XCTAssertEqual(firstPersistedEntry.lastError, SharedErrorDescriptor.healthKitUnavailableFallback.diagnosticSafeDetail)
        XCTAssertFalse(firstPersistedEntry.lastError?.contains("FakeHealthStoreError") ?? true)

        await worker.processPending(in: context, now: firstAttempt.addingTimeInterval(86_400))
        XCTAssertEqual(try XCTUnwrap(persistedOutboxSnapshots()[entry.id]).state, "succeeded")
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
        try await repository.insert(meal)
        meal.totalCaloriesKcal = 580
        meal.energyLikelyKcal = 580
        meal.proteinLikelyG = 31
        try await repository.updateMeal(id: meal.id)

        let entries = try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>())
            .sorted { $0.syncVersion < $1.syncVersion }
        XCTAssertEqual(entries.map(\.syncVersion), [1, 2])
        XCTAssertEqual(entries[0].syncIdentifier, entries[1].syncIdentifier)

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        let persisted = try persistedOutboxSnapshots()
        XCTAssertEqual(persisted[entries[0].id]?.state, "succeeded")
        XCTAssertEqual(persisted[entries[1].id]?.state, "succeeded")
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

    func testFailedSupersededWriteDoesNotOverwriteNewReceiptOrRetryOldVersion() async throws {
        try await assertSupersededWritePreservesPendingReceipt(failOldWrite: true)
    }

    func testSuccessfulSupersededWriteDoesNotOverwriteNewReceipt() async throws {
        try await assertSupersededWritePreservesPendingReceipt(failOldWrite: false)
    }

    func testSupersededReceiptReconciliationDoesNotOverwriteNewReceiptState() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = false
        let meal = MealRecord(date: Date(timeIntervalSince1970: 1_800_000_000), totalCaloriesKcal: 430)
        let receiptID = UUID()
        let oldOutbox = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: meal.id,
            receiptID: receiptID,
            state: "receiptReconciliation-retryable",
            syncIdentifier: "densoso.meal.\(meal.id.uuidString.lowercased())",
            syncVersion: 1
        )
        let newOutbox = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: meal.id,
            receiptID: receiptID,
            state: HealthSyncState.pending.rawValue,
            syncIdentifier: oldOutbox.syncIdentifier,
            syncVersion: 2
        )
        let receipt = CommittedActionReceiptRecord(
            id: receiptID,
            actionID: UUID(),
            idempotencyKey: "superseded-reconciliation-\(receiptID.uuidString.lowercased())",
            actionTypeRaw: ActionType.meal.rawValue,
            localRecordID: meal.id,
            outboxIDsData: try JSONEncoder().encode([oldOutbox.id, newOutbox.id]),
            healthSyncStateRaw: HealthSyncState.pending.rawValue
        )
        context.insert(meal)
        context.insert(oldOutbox)
        context.insert(newOutbox)
        context.insert(receipt)
        try context.save()

        let healthStore = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: healthStore, modelContainer: container)
            .processPending(in: context)

        let persisted = try persistedOutboxSnapshots()
        XCTAssertEqual(persisted[oldOutbox.id]?.state, "succeeded")
        XCTAssertEqual(persisted[newOutbox.id]?.state, HealthSyncState.pending.rawValue)
        XCTAssertEqual(try persistedActionReceiptState(id: receiptID), HealthSyncState.pending.rawValue)
        let attemptedWrites = await healthStore.attemptedWritesSnapshot()
        XCTAssertTrue(attemptedWrites.isEmpty)
    }

    private func assertSupersededWritePreservesPendingReceipt(failOldWrite: Bool) async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let meal = MealRecord(date: now, totalCaloriesKcal: 430, energyLikelyKcal: 430)
        let receiptID = UUID()
        let oldOutbox = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: meal.id,
            receiptID: receiptID,
            syncIdentifier: "densoso.meal.\(meal.id.uuidString.lowercased())",
            syncVersion: 1
        )
        let receipt = CommittedActionReceiptRecord(
            id: receiptID,
            actionID: UUID(),
            idempotencyKey: "superseded-outbox-\(receiptID.uuidString.lowercased())",
            actionTypeRaw: ActionType.meal.rawValue,
            localRecordID: meal.id,
            outboxIDsData: try JSONEncoder().encode([oldOutbox.id]),
            healthSyncStateRaw: HealthSyncState.succeeded.rawValue
        )
        context.insert(meal)
        context.insert(oldOutbox)
        context.insert(receipt)
        try context.save()

        let healthStore = FakeHealthStoreClient()
        await healthStore.blockNextHealthWrite()
        if failOldWrite { await healthStore.failNextWrites(1) }
        let worker = HealthSyncOutboxWorker(healthStore: healthStore, modelContainer: container)
        let processingTask = Task {
            await worker.processPending(in: context, now: now)
        }
        await healthStore.waitUntilHealthWriteIsBlocked()

        try await HealthRepository(modelContext: ModelContext(container)).updateMeal(id: meal.id)
        let updateContext = ModelContext(container)
        let mealID = meal.id
        let updatedEntries = try updateContext.fetch(
            FetchDescriptor<HealthSyncOutboxEntry>(predicate: #Predicate { $0.recordID == mealID })
        )
        let newOutbox = try XCTUnwrap(updatedEntries.first { $0.syncVersion == 2 })
        XCTAssertEqual(newOutbox.state, HealthSyncState.pending.rawValue)
        XCTAssertEqual(newOutbox.receiptID, receiptID)
        // Keep v2 pending for this run so assertions observe the commit of v1
        // independently from the subsequent retry of the newest generation.
        newOutbox.nextAttemptAt = Date(timeIntervalSince1970: 4_000_000_000)
        try updateContext.save()
        XCTAssertEqual(try persistedActionReceiptState(id: receiptID), HealthSyncState.pending.rawValue)

        await healthStore.resumeBlockedHealthWrite()
        await processingTask.value

        let persisted = try persistedOutboxSnapshots()
        XCTAssertEqual(persisted[oldOutbox.id]?.state, "succeeded")
        XCTAssertEqual(persisted[oldOutbox.id]?.attemptCount, 1)
        XCTAssertEqual(persisted[newOutbox.id]?.state, "pending")
        XCTAssertEqual(try persistedActionReceiptState(id: receiptID), HealthSyncState.pending.rawValue)
        let attemptedWrites = await healthStore.attemptedWritesSnapshot()
        XCTAssertEqual(attemptedWrites.count, 1, "The obsolete generation must not be retried")
        let successfulWrites = await healthStore.successfulWritesSnapshot()
        XCTAssertEqual(successfulWrites.count, failOldWrite ? 0 : 1)
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
        newer.createdAt = now.addingTimeInterval(TimeInterval(HealthSyncOutboxWorker.outboxBatchSize + 1))
        context.insert(newer)
        try context.save()

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context, now: now)

        let persisted = try persistedOutboxSnapshots()
        XCTAssertEqual(persisted[older.id]?.state, "succeeded")
        XCTAssertEqual(persisted[older.id]?.attemptCount, 1)
        XCTAssertEqual(persisted[newer.id]?.state, "retryable")
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

        XCTAssertEqual(try XCTUnwrap(persistedOutboxSnapshots()[entry.id]).state, "pending")
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

        let persistedEntry = try XCTUnwrap(persistedOutboxSnapshots()[entry.id])
        XCTAssertEqual(persistedEntry.state, "succeeded")
        XCTAssertEqual(persistedEntry.attemptCount, 2)
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

        let persisted = try persistedOutboxSnapshots()
        XCTAssertEqual(persisted[dueEntry.id]?.state, "succeeded")
        XCTAssertEqual(persisted[dueEntry.id]?.attemptCount, 1)
        XCTAssertEqual(persisted[futureEntry.id]?.state, "retryable")
        XCTAssertEqual(persisted[futureEntry.id]?.attemptCount, 3)
        XCTAssertEqual(persisted[terminalEntry.id]?.state, "terminal")
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

        let persisted = try persistedOutboxSnapshots()
        XCTAssertTrue(entries.allSatisfy {
            persisted[$0.id]?.state == "succeeded" && persisted[$0.id]?.attemptCount == 1
        })
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

        XCTAssertEqual(try XCTUnwrap(persistedOutboxSnapshots()[entry.id]).state, "succeeded")
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
        try await repository.updateWeight(id: weight.id)
        weight.kilograms = 67.8
        try await repository.updateWeight(id: weight.id)
        try await repository.deleteWeight(id: weight.id)

        let entries = try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>())
            .sorted { $0.syncVersion < $1.syncVersion }
        XCTAssertEqual(entries.map(\.syncVersion), [1, 2, 3])
        XCTAssertEqual(Set(entries.map(\.syncIdentifier)).count, 1)

        let fake = FakeHealthStoreClient()
        await HealthSyncOutboxWorker(healthStore: fake, modelContainer: container)
            .processPending(in: context)

        let persisted = try persistedOutboxSnapshots()
        XCTAssertTrue(entries.allSatisfy { persisted[$0.id]?.state == "succeeded" })
        let writes = await fake.successfulWritesSnapshot()
        let deletes = await fake.deletedReceiptsSnapshot()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(deletes.first?.syncVersion, 3)
        XCTAssertEqual(deletes.first?.metrics, [.bodyMass])
    }

    func testConcurrentContextsAllocateDistinctSyncVersionsForSameRecord() async throws {
        let meal = MealRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 430,
            energyLikelyKcal: 430
        )
        context.insert(meal)
        try context.save()

        let firstRepository = HealthRepository(modelContext: ModelContext(container))
        let secondRepository = HealthRepository(modelContext: ModelContext(container))
        let firstUpdate = Task { try await firstRepository.updateMeal(id: meal.id) }
        let secondUpdate = Task { try await secondRepository.updateMeal(id: meal.id) }
        try await firstUpdate.value
        try await secondUpdate.value

        let verificationContext = ModelContext(container)
        let mealID = meal.id
        let entries = try verificationContext.fetch(
            FetchDescriptor<HealthSyncOutboxEntry>(predicate: #Predicate { $0.recordID == mealID })
        )
        let versions = entries.map(\.syncVersion).sorted()
        XCTAssertEqual(versions, [1, 2])
        XCTAssertEqual(Set(versions).count, versions.count)
    }

    func testReceiptLookupFailureLeavesRecoverableReconciliationState() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let meal = MealRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 430,
            energyLikelyKcal: 430
        )
        let receiptID = UUID()
        let outbox = HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: meal.id,
            receiptID: receiptID
        )
        let actionReceipt = CommittedActionReceiptRecord(
            id: receiptID,
            actionID: UUID(),
            idempotencyKey: "receipt-reconciliation-test",
            actionTypeRaw: ActionType.meal.rawValue,
            localRecordID: meal.id,
            outboxIDsData: try JSONEncoder().encode([outbox.id]),
            healthSyncStateRaw: "sending"
        )
        context.insert(meal)
        context.insert(outbox)
        context.insert(actionReceipt)
        try context.save()

        let healthStore = FakeHealthStoreClient()
        let failingWorker = HealthSyncOutboxWorker(
            healthStore: healthStore,
            modelContainer: container,
            willFetchActionReceipt: { throw OutboxReceiptLookupError.injected }
        )
        await failingWorker.processPending(in: context)
        let afterFirstRun = try XCTUnwrap(persistedOutboxSnapshots()[outbox.id])
        XCTAssertEqual(afterFirstRun.state, "receiptReconciliation-succeeded")
        XCTAssertNotNil(afterFirstRun.lastError)
        XCTAssertEqual(try persistedActionReceiptState(id: receiptID), "sending")

        await HealthSyncOutboxWorker(healthStore: healthStore, modelContainer: container)
            .processPending(in: context)
        XCTAssertEqual(try XCTUnwrap(persistedOutboxSnapshots()[outbox.id]).state, "succeeded")
        XCTAssertEqual(try persistedActionReceiptState(id: receiptID), "succeeded")
        let successfulWrites = await healthStore.successfulWritesSnapshot()
        XCTAssertEqual(successfulWrites.count, 1)
    }

    func testExternalSuccessWithLocalCommitFailureRecoversSucceededStateWithoutDuplicate() async throws {
        HealthKitConnectionPreference.hasRequestedAuthorization = true
        let meal = MealRecord(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            totalCaloriesKcal: 430,
            energyLikelyKcal: 430
        )
        let outbox = HealthSyncOutboxEntry(operation: "upsertMeal", recordID: meal.id)
        context.insert(meal)
        context.insert(outbox)
        try context.save()

        let healthStore = FakeHealthStoreClient()
        let failingWorker = HealthSyncOutboxWorker(
            healthStore: healthStore,
            modelContainer: container,
            willCommitExternalSuccess: { throw OutboxLocalCommitError.injected }
        )
        await failingWorker.processPending(in: context)
        XCTAssertEqual(try XCTUnwrap(persistedOutboxSnapshots()[outbox.id]).state, "succeeded")
        let firstWrites = await healthStore.successfulWritesSnapshot()
        XCTAssertEqual(firstWrites.count, 1)

        let persistedContext = ModelContext(container)
        let outboxID = outbox.id
        let persistedEntry = try XCTUnwrap(
            persistedContext.fetch(
                FetchDescriptor<HealthSyncOutboxEntry>(predicate: #Predicate { $0.id == outboxID })
            ).first
        )
        XCTAssertEqual(persistedEntry.state, "succeeded")
        XCTAssertEqual(persistedEntry.syncVersion, 1)
        XCTAssertNil(persistedEntry.lastError)

        await HealthSyncOutboxWorker(healthStore: healthStore, modelContainer: container)
            .processPending()
        let replayedWrites = await healthStore.successfulWritesSnapshot()
        XCTAssertEqual(replayedWrites.count, 1)
    }

    private struct PersistedOutboxSnapshot {
        let state: String
        let attemptCount: Int
        let lastError: String?
        let syncIdentifier: String
        let payloadData: Data
    }

    private func persistedOutboxSnapshots() throws -> [UUID: PersistedOutboxSnapshot] {
        let verificationContext = ModelContext(container)
        let entries = try verificationContext.fetch(FetchDescriptor<HealthSyncOutboxEntry>())
        return Dictionary(uniqueKeysWithValues: entries.map { entry in
            (entry.id, PersistedOutboxSnapshot(
                state: entry.state,
                attemptCount: entry.attemptCount,
                lastError: entry.lastError,
                syncIdentifier: entry.syncIdentifier,
                payloadData: entry.payloadData
            ))
        })
    }

    private func persistedActionReceiptState(id: UUID) throws -> String? {
        let verificationContext = ModelContext(container)
        let receiptID = id
        let receipt = try verificationContext.fetch(
            FetchDescriptor<CommittedActionReceiptRecord>(predicate: #Predicate { $0.id == receiptID })
        ).first
        return receipt?.healthSyncStateRaw
    }
}

extension FakeHealthStoreClient {
    func attemptedWritesSnapshot() -> [HealthWriteCommand] { attemptedWrites }
    func successfulWritesSnapshot() -> [HealthWriteCommand] { successfulWrites }
    func deletedReceiptsSnapshot() -> [HealthWriteReceipt] { deletedReceipts }
}

private enum OutboxReceiptLookupError: Error {
    case injected
}

private enum OutboxLocalCommitError: Error {
    case injected
}
