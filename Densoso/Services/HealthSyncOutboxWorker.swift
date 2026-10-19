import Foundation
import SwiftData
import DensosoDomain

@MainActor
final class HealthSyncOutboxWorker: HealthSyncOutboxProcessing {
    static let outboxBatchSize = 64

    private let healthStore: any HealthStoreClient
    private let modelContainer: ModelContainer
    private let maximumAttempts = 8
    private var isProcessing = false

    private struct OutboxCursor {
        let createdAt: Date
        let idempotencyKey: String
    }

    init(healthStore: any HealthStoreClient, modelContainer: ModelContainer) {
        self.healthStore = healthStore
        self.modelContainer = modelContainer
    }

    func processPending() async {
        await processPending(in: modelContainer.mainContext)
    }

    func processPending(in modelContext: ModelContext, now: Date = Date()) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
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
        var cursor: OutboxCursor?
        while true {
            guard let candidates = try? pendingBatch(after: cursor, in: modelContext) else { return }
            guard !candidates.isEmpty else { break }

            for entry in candidates {
                cursor = OutboxCursor(createdAt: entry.createdAt, idempotencyKey: entry.idempotencyKey)
                guard entry.nextAttemptAt == nil || entry.nextAttemptAt! <= now else { continue }
                if let canonicalIdentifier = HealthRepository.canonicalSyncIdentifier(
                    operation: entry.operation,
                    recordID: entry.recordID
                ) {
                    entry.syncIdentifier = canonicalIdentifier
                }
                entry.state = "sending"
                entry.attemptCount += 1
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    return
                }

                do {
                    let superseded = try isSuperseded(entry, in: modelContext)
                    if superseded {
                        entry.state = "succeeded"
                        entry.lastError = nil
                    } else if entry.operation == "deleteMeal" || entry.operation == "deleteWeight" {
                        let receipt = deleteReceipt(for: entry)
                        try await healthStore.deleteOwnSample(receipt: receipt)
                        entry.payloadData = try JSONEncoder().encode(receipt)
                        entry.state = "succeeded"
                        entry.lastError = nil
                    } else if entry.operation == "upsertWorkout" || entry.operation == "deleteWorkout" {
                        throw HealthOutboxError.unsupportedOperation("Workout HealthKit writes are disabled in V3.")
                    } else {
                        let command = try writeCommand(for: entry, in: modelContext)
                        let receipt = try await healthStore.save(command)
                        entry.payloadData = try JSONEncoder().encode(receipt)
                        entry.state = "succeeded"
                        entry.lastError = nil
                    }
                    entry.nextAttemptAt = nil
                    if !superseded { updateActionReceipt(for: entry, in: modelContext, state: "succeeded") }
                    try modelContext.save()
                } catch {
                    let terminal = isTerminal(error) || entry.attemptCount >= maximumAttempts
                    entry.state = terminal ? "terminal" : "retryable"
                    entry.lastError = String(String(describing: error).prefix(500))
                    let delay = min(pow(2.0, Double(min(entry.attemptCount, 10))) * 30, 21_600)
                    entry.nextAttemptAt = terminal ? nil : now.addingTimeInterval(delay)
                    updateActionReceipt(for: entry, in: modelContext, state: entry.state)
                    do { try modelContext.save() }
                    catch { modelContext.rollback(); return }
                }
            }
        }
    }

    private func pendingBatch(
        after cursor: OutboxCursor?,
        in modelContext: ModelContext
    ) throws -> [HealthSyncOutboxEntry] {
        let pendingState = "pending"
        let retryableState = "retryable"
        let sortBy = [
            SortDescriptor(\HealthSyncOutboxEntry.createdAt),
            SortDescriptor(\HealthSyncOutboxEntry.idempotencyKey),
        ]
        var descriptor: FetchDescriptor<HealthSyncOutboxEntry>
        if let cursor {
            let cursorCreatedAt = cursor.createdAt
            let cursorIdempotencyKey = cursor.idempotencyKey
            let predicate = #Predicate<HealthSyncOutboxEntry> {
                ($0.state == pendingState || $0.state == retryableState)
                    && ($0.createdAt > cursorCreatedAt
                        || ($0.createdAt == cursorCreatedAt && $0.idempotencyKey > cursorIdempotencyKey))
            }
            descriptor = FetchDescriptor(predicate: predicate, sortBy: sortBy)
        } else {
            let predicate = #Predicate<HealthSyncOutboxEntry> {
                $0.state == pendingState || $0.state == retryableState
            }
            descriptor = FetchDescriptor(predicate: predicate, sortBy: sortBy)
        }
        descriptor.fetchLimit = Self.outboxBatchSize
        return try modelContext.fetch(descriptor)
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
            let payload = HealthWritePayload.nutrition(HealthNutritionWrite(
                energyKilocalories: meal.energyLikelyKcal,
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

    private func updateActionReceipt(for entry: HealthSyncOutboxEntry, in modelContext: ModelContext, state: String) {
        guard let receiptID = entry.receiptID else { return }
        var descriptor = FetchDescriptor<CommittedActionReceiptRecord>(
            predicate: #Predicate { $0.id == receiptID }
        )
        descriptor.fetchLimit = 1
        guard let records = try? modelContext.fetch(descriptor),
              let receipt = records.first else { return }
        receipt.healthSyncStateRaw = state
    }

    private func isTerminal(_ error: Error) -> Bool {
        if let healthError = error as? HealthStoreClientError {
            switch healthError {
            case .authorizationDenied, .healthDataRestricted, .unsupportedMetric:
                return true
            case .unavailable, .authorizationNotDetermined, .dataStoreLocked, .invalidAnchor, .queryFailed:
                return false
            }
        }
        guard let error = error as? HealthOutboxError else { return false }
        switch error {
        case .missingSourceRecord, .refuseHealthKitEcho, .unsupportedOperation:
            return true
        }
    }
}

private enum HealthOutboxError: Error {
    case missingSourceRecord
    case refuseHealthKitEcho
    case unsupportedOperation(String)
}
