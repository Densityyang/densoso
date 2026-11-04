import Foundation
import SwiftData
import DensosoDomain

@MainActor
final class HealthSyncOutboxWorker: HealthSyncOutboxProcessing {
    static let outboxBatchSize = 64

    private let healthStore: any HealthStoreClient
    private let modelContainer: ModelContainer
    private let persistenceOperationBarrier: PersistenceOperationBarrier
    private let willFetchActionReceipt: (() throws -> Void)?
    private let willCommitExternalSuccess: (() throws -> Void)?
    private let maximumAttempts = 8
    private var isProcessing = false

    private static let receiptReconciliationTargets = ["succeeded", "retryable", "terminal"]

    private struct OutboxCursor {
        let createdAt: Date
        let idempotencyKey: String
    }

    private struct PendingOutboxCursor {
        let createdAt: Date
        let id: UUID
    }

    init(
        healthStore: any HealthStoreClient,
        modelContainer: ModelContainer,
        persistenceOperationBarrier: PersistenceOperationBarrier = .shared,
        willFetchActionReceipt: (() throws -> Void)? = nil,
        willCommitExternalSuccess: (() throws -> Void)? = nil
    ) {
        self.healthStore = healthStore
        self.modelContainer = modelContainer
        self.persistenceOperationBarrier = persistenceOperationBarrier
        self.willFetchActionReceipt = willFetchActionReceipt
        self.willCommitExternalSuccess = willCommitExternalSuccess
    }

    func processPending() async {
        await run(in: ModelContext(modelContainer), now: Date())
    }

    func processPending(in requestingContext: ModelContext, now: Date = Date()) async {
        await run(in: ModelContext(requestingContext.container), now: now)
    }

    private func run(in modelContext: ModelContext, now: Date) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        let operationLease: PersistenceOperationBarrier.Lease
        do {
            operationLease = try await persistenceOperationBarrier.acquireOutboxOperation()
        } catch {
            return
        }
        defer { persistenceOperationBarrier.release(operationLease) }
        await persistenceOperationBarrier.withLease(operationLease) {
            await self.runWithOperationLease(in: modelContext, now: now)
        }
    }

    private func runWithOperationLease(in modelContext: ModelContext, now: Date) async {
        guard !Task.isCancelled else { return }
        reconcileActionReceipts(in: modelContext)
        guard HealthKitConnectionPreference.hasRequestedAuthorization else { return }
        let sendingState = "sending"
        let recoverySort = [
            SortDescriptor(\HealthSyncOutboxEntry.createdAt),
            SortDescriptor(\HealthSyncOutboxEntry.idempotencyKey),
        ]
        while true {
            let sendingPredicate = #Predicate<HealthSyncOutboxEntry> { $0.state == sendingState }
            var sendingDescriptor = FetchDescriptor<HealthSyncOutboxEntry>(
                predicate: sendingPredicate,
                sortBy: recoverySort
            )
            sendingDescriptor.fetchLimit = Self.outboxBatchSize
            guard let interruptedEntries = try? modelContext.fetch(sendingDescriptor) else { return }
            guard !interruptedEntries.isEmpty else { break }
            for entry in interruptedEntries {
                entry.state = "retryable"
                entry.nextAttemptAt = now
            }
            do { try modelContext.save() }
            catch { modelContext.rollback(); return }
        }
        guard await healthStore.isAvailable() else { return }
        var pendingCursor: PendingOutboxCursor?
        while true {
            guard let candidates = try? pendingBatch(after: pendingCursor, in: modelContext) else { return }
            guard !candidates.isEmpty else { break }

            for entry in candidates {
                // Advance for every row, including future retries, so each bounded page is visited once.
                pendingCursor = PendingOutboxCursor(createdAt: entry.createdAt, id: entry.id)
                guard entry.nextAttemptAt == nil || entry.nextAttemptAt! <= now else { continue }
                if let canonicalIdentifier = HealthRepository.canonicalSyncIdentifier(
                    operation: entry.operation,
                    recordID: entry.recordID
                ) {
                    entry.syncIdentifier = canonicalIdentifier
                }
                entry.state = "sending"
                entry.attemptCount += 1
                let operationGeneration = entry.attemptCount
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    return
                }

                var externalReceipt: HealthWriteReceipt?
                var externalOperationCompleted = false
                var shouldUpdateActionReceipt = false
                do {
                    // The caller's context may have been alive before another
                    // context committed a newer outbox generation. Start the
                    // external operation from a fresh store view.
                    let executionContext = ModelContext(modelContainer)
                    guard let executionEntry = try activeOperationEntry(
                        id: entry.id,
                        generation: operationGeneration,
                        in: executionContext
                    ) else { continue }
                    let superseded = try isSuperseded(executionEntry, in: executionContext)
                    if !superseded {
                        if executionEntry.operation == "deleteMeal" || executionEntry.operation == "deleteWeight" {
                            let receipt = deleteReceipt(for: executionEntry)
                            try await healthStore.deleteOwnSample(receipt: receipt)
                            externalReceipt = receipt
                            externalOperationCompleted = true
                        } else if executionEntry.operation == "upsertWorkout" || executionEntry.operation == "deleteWorkout" {
                            throw HealthOutboxError.unsupportedOperation("Workout HealthKit writes are disabled in V3.")
                        } else {
                            let command = try writeCommand(for: executionEntry, in: executionContext)
                            externalReceipt = try await healthStore.save(command)
                            externalOperationCompleted = true
                        }
                    }

                    // The external operation may suspend while another local write
                    // supersedes this entry. Re-fetch by ID and validate the attempt
                    // generation in a new context before committing its result.
                    let commitContext = ModelContext(modelContainer)
                    guard let currentEntry = try activeOperationEntry(
                        id: entry.id,
                        generation: operationGeneration,
                        in: commitContext
                    ) else { continue }
                    let supersededAfterExternalOperation = try isSuperseded(currentEntry, in: commitContext)
                    shouldUpdateActionReceipt = !superseded && !supersededAfterExternalOperation
                    if let externalReceipt {
                        currentEntry.payloadData = try JSONEncoder().encode(externalReceipt)
                    }
                    currentEntry.state = "succeeded"
                    currentEntry.lastError = nil
                    currentEntry.nextAttemptAt = nil
                    if shouldUpdateActionReceipt {
                        try updateActionReceipt(for: currentEntry, in: commitContext, state: "succeeded")
                    }
                    if externalOperationCompleted { try willCommitExternalSuccess?() }
                    try commitContext.save()
                } catch {
                    modelContext.rollback()
                    let reconciliationContext = ModelContext(modelContainer)
                    guard let currentEntry = try? activeOperationEntry(
                        id: entry.id,
                        generation: operationGeneration,
                        in: reconciliationContext
                    ) else { continue }
                    let terminal = isTerminal(error) || currentEntry.attemptCount >= maximumAttempts
                    let targetState = externalOperationCompleted
                        ? "succeeded"
                        : (terminal ? "terminal" : "retryable")
                    if let externalReceipt,
                       let receiptData = try? JSONEncoder().encode(externalReceipt) {
                        currentEntry.payloadData = receiptData
                    }
                    currentEntry.state = targetState
                    currentEntry.lastError = targetState == "succeeded"
                        ? nil
                        : SharedErrorDescriptor.mapped(
                            from: error,
                            fallback: .healthKitUnavailableFallback
                        ).diagnosticSafeDetail
                    let delay = min(pow(2.0, Double(min(currentEntry.attemptCount, 10))) * 30, 21_600)
                    currentEntry.nextAttemptAt = targetState == "retryable" ? now.addingTimeInterval(delay) : nil
                    do {
                        if shouldUpdateActionReceipt || !externalOperationCompleted {
                            try updateActionReceipt(for: currentEntry, in: reconciliationContext, state: targetState)
                        }
                        try reconciliationContext.save()
                    } catch {
                        reconciliationContext.rollback()
                        let recoveryContext = ModelContext(modelContainer)
                        guard let recoverableEntry = try? activeOperationEntry(
                            id: entry.id,
                            generation: operationGeneration,
                            in: recoveryContext
                        ) else { continue }
                        recoverableEntry.state = Self.receiptReconciliationState(for: targetState)
                        recoverableEntry.lastError = "\(SharedErrorDescriptor.mapped(from: error, fallback: .healthKitUnavailableFallback).diagnosticSafeDetail) Receipt reconciliation pending."
                        recoverableEntry.nextAttemptAt = targetState == "retryable"
                            ? now.addingTimeInterval(delay)
                            : nil
                        do { try recoveryContext.save() }
                        catch { recoveryContext.rollback(); return }
                    }
                }
            }
        }
    }

    private func pendingBatch(
        after cursor: PendingOutboxCursor?,
        in modelContext: ModelContext
    ) throws -> [HealthSyncOutboxEntry] {
        let pendingState = "pending"
        let retryableState = "retryable"
        let sortBy = [
            SortDescriptor(\HealthSyncOutboxEntry.createdAt),
            SortDescriptor(\HealthSyncOutboxEntry.id),
        ]
        let predicate: Predicate<HealthSyncOutboxEntry>
        if let cursor {
            let cursorCreatedAt = cursor.createdAt
            let cursorID = cursor.id
            predicate = #Predicate<HealthSyncOutboxEntry> { entry in
                (entry.state == pendingState || entry.state == retryableState)
                    && (entry.createdAt > cursorCreatedAt
                        || (entry.createdAt == cursorCreatedAt && entry.id > cursorID))
            }
        } else {
            predicate = #Predicate<HealthSyncOutboxEntry> { entry in
                entry.state == pendingState || entry.state == retryableState
            }
        }
        var descriptor = FetchDescriptor<HealthSyncOutboxEntry>(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = Self.outboxBatchSize
        return try modelContext.fetch(descriptor)
    }

    private func activeOperationEntry(
        id: UUID,
        generation: Int,
        in modelContext: ModelContext
    ) throws -> HealthSyncOutboxEntry? {
        let entryID = id
        let attemptGeneration = generation
        let sendingState = "sending"
        var descriptor = FetchDescriptor<HealthSyncOutboxEntry>(
            predicate: #Predicate {
                $0.id == entryID && $0.state == sendingState && $0.attemptCount == attemptGeneration
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func receiptReconciliationState(for target: String) -> String {
        "receiptReconciliation-\(target)"
    }

    private func reconcileActionReceipts(in modelContext: ModelContext) {
        let sortBy = [
            SortDescriptor(\HealthSyncOutboxEntry.createdAt),
            SortDescriptor(\HealthSyncOutboxEntry.id),
        ]
        for target in Self.receiptReconciliationTargets {
            let reconciliationState = Self.receiptReconciliationState(for: target)
            while true {
                var descriptor = FetchDescriptor<HealthSyncOutboxEntry>(
                    predicate: #Predicate { $0.state == reconciliationState },
                    sortBy: sortBy
                )
                descriptor.fetchLimit = Self.outboxBatchSize
                guard let entries = try? modelContext.fetch(descriptor) else { return }
                guard !entries.isEmpty else { break }
                for entry in entries {
                    do {
                        try updateActionReceipt(for: entry, in: modelContext, state: target)
                        entry.state = target
                        entry.lastError = nil
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        return
                    }
                }
            }
        }
    }

    private func writeCommand(for entry: HealthSyncOutboxEntry, in modelContext: ModelContext) throws -> HealthWriteCommand {
        if entry.operation == "upsertMeal" {
            let recordID = entry.recordID
            var descriptor = FetchDescriptor<MealRecord>(
                predicate: #Predicate { $0.id == recordID }
            )
            descriptor.fetchLimit = 1
            guard let meal = try modelContext.fetch(descriptor).first else {
                throw HealthOutboxError.missingSourceRecord
            }
            let energyKilocalories = meal.energyLikelyKcal
            guard energyKilocalories.isFinite, energyKilocalories >= 0 else {
                throw HealthOutboxError.unavailableMealEnergy
            }
            if energyKilocalories == 0 {
                let evidence = meal.evidenceData.flatMap {
                    try? JSONDecoder().decode([EvidenceSnapshot].self, from: $0)
                } ?? []
                guard MealEnergyAvailabilityPolicy.supportsExplicitZero(evidence) else {
                    throw HealthOutboxError.unavailableMealEnergy
                }
            }
            let payload = HealthWritePayload.nutrition(HealthNutritionWrite(
                energyKilocalories: energyKilocalories,
                proteinGrams: meal.proteinLikelyG,
                fatGrams: meal.fatLikelyG,
                carbohydrateGrams: meal.carbsLikelyG
            ))
            return HealthWriteCommand(
                recordID: meal.id,
                occurredAt: meal.date,
                syncIdentifier: entry.syncIdentifier,
                syncVersion: entry.syncVersion,
                payload: payload
            )
        }

        if entry.operation == "upsertWeight" {
            let recordID = entry.recordID
            var descriptor = FetchDescriptor<WeightRecord>(
                predicate: #Predicate { $0.id == recordID }
            )
            descriptor.fetchLimit = 1
            guard let weight = try modelContext.fetch(descriptor).first else {
                throw HealthOutboxError.missingSourceRecord
            }
            guard weight.source != "healthKit" else { throw HealthOutboxError.refuseHealthKitEcho }
            return HealthWriteCommand(
                recordID: weight.id,
                occurredAt: weight.measuredAt,
                syncIdentifier: entry.syncIdentifier,
                syncVersion: entry.syncVersion,
                payload: .confirmedWeight(kilograms: weight.kilograms)
            )
        }

        throw HealthOutboxError.unsupportedOperation(entry.operation)
    }

    private func deleteReceipt(for entry: HealthSyncOutboxEntry) -> HealthWriteReceipt {
        let metrics: [HealthMetricID] = entry.operation.lowercased().contains("meal")
            ? [.dietaryEnergy, .dietaryProtein, .dietaryFat, .dietaryCarbohydrates]
            : [.bodyMass]
        return HealthWriteReceipt(
            recordID: entry.recordID,
            syncIdentifier: entry.syncIdentifier,
            syncVersion: entry.syncVersion,
            metrics: metrics,
            sampleIDs: []
        )
    }

    private func isSuperseded(_ entry: HealthSyncOutboxEntry, in modelContext: ModelContext) throws -> Bool {
        let recordID = entry.recordID
        let minimumSyncVersion = entry.syncVersion
        let entryIdentifier = HealthRepository.canonicalSyncIdentifier(
            operation: entry.operation,
            recordID: entry.recordID
        ) ?? entry.syncIdentifier
        let sortBy = [
            SortDescriptor(\HealthSyncOutboxEntry.createdAt),
            SortDescriptor(\HealthSyncOutboxEntry.idempotencyKey),
        ]
        var cursor: OutboxCursor?
        while true {
            let predicate: Predicate<HealthSyncOutboxEntry>
            if let cursor {
                let cursorCreatedAt = cursor.createdAt
                let cursorIdempotencyKey = cursor.idempotencyKey
                predicate = #Predicate<HealthSyncOutboxEntry> { candidate in
                    candidate.recordID == recordID
                        && candidate.syncVersion > minimumSyncVersion
                        && (candidate.createdAt > cursorCreatedAt
                            || (candidate.createdAt == cursorCreatedAt
                                && candidate.idempotencyKey > cursorIdempotencyKey))
                }
            } else {
                predicate = #Predicate<HealthSyncOutboxEntry> { candidate in
                    candidate.recordID == recordID && candidate.syncVersion > minimumSyncVersion
                }
            }
            var descriptor = FetchDescriptor<HealthSyncOutboxEntry>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.outboxBatchSize
            let candidates = try modelContext.fetch(descriptor)
            guard !candidates.isEmpty else { return false }

            for candidate in candidates {
                let candidateIdentifier = HealthRepository.canonicalSyncIdentifier(
                    operation: candidate.operation,
                    recordID: candidate.recordID
                ) ?? candidate.syncIdentifier
                if candidate.id != entry.id && candidateIdentifier == entryIdentifier {
                    return true
                }
            }

            guard let lastCandidate = candidates.last else { return false }
            cursor = OutboxCursor(
                createdAt: lastCandidate.createdAt,
                idempotencyKey: lastCandidate.idempotencyKey
            )
            if candidates.count < Self.outboxBatchSize { return false }
        }
    }

    private func updateActionReceipt(
        for entry: HealthSyncOutboxEntry,
        in modelContext: ModelContext,
        state: String
    ) throws {
        guard let receiptID = entry.receiptID else { return }
        try willFetchActionReceipt?()
        var descriptor = FetchDescriptor<CommittedActionReceiptRecord>(
            predicate: #Predicate { $0.id == receiptID }
        )
        descriptor.fetchLimit = 1
        let records = try modelContext.fetch(descriptor)
        guard let receipt = records.first else { throw HealthOutboxError.missingActionReceipt }
        receipt.healthSyncStateRaw = state
    }

    private func isTerminal(_ error: Error) -> Bool {
        if let healthError = error as? HealthStoreClientError {
            switch healthError {
            case .authorizationDenied, .healthDataRestricted, .unsupportedMetric:
                return true
            case .unavailable, .authorizationBoundaryUnavailable, .authorizationNotDetermined,
                 .dataStoreLocked, .invalidAnchor, .queryFailed:
                return false
            }
        }
        guard let error = error as? HealthOutboxError else { return false }
        switch error {
        case .missingActionReceipt:
            return false
        case .missingSourceRecord, .refuseHealthKitEcho, .unavailableMealEnergy, .unsupportedOperation:
            return true
        }
    }
}

private enum HealthOutboxError: SharedErrorDescribing {
    case missingSourceRecord
    case missingActionReceipt
    case refuseHealthKitEcho
    case unavailableMealEnergy
    case unsupportedOperation(String)

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .missingSourceRecord:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "源记录已不可用，无法同步到 Apple Health。",
                subsystem: .healthKit,
                reason: .actionNotFound
            )
        case .missingActionReceipt:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "操作回执暂不可用，健康同步状态将在后续重试中对账。",
                subsystem: .healthKit,
                reason: .actionNotFound
            )
        case .refuseHealthKitEcho:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "此记录来自 Apple Health，无需再次写回。",
                subsystem: .healthKit,
                reason: .refusedHealthKitEcho
            )
        case .unavailableMealEnergy:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "该餐食热量来源无法确认，因此未写入 Apple Health。",
                subsystem: .healthKit,
                reason: .healthMealEnergyUnavailable
            )
        case .unsupportedOperation(_):
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "该记录类型暂不支持 Apple Health 同步。",
                subsystem: .healthKit,
                reason: .unsupportedHealthMetric
            )
        }
    }
}
