import Foundation
import SwiftData
import DensosoDomain

@MainActor
final class HealthSyncOutboxWorker: HealthSyncOutboxProcessing {
    private let healthStore: any HealthStoreClient
    private let modelContainer: ModelContainer
    private let maximumAttempts = 8
    private var isProcessing = false

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
        guard let entries = try? modelContext.fetch(FetchDescriptor<HealthSyncOutboxEntry>()) else { return }
        var recoveredSending = false
        for entry in entries where entry.state == "sending" {
            entry.state = "retryable"
            entry.nextAttemptAt = now
            recoveredSending = true
        }
        if recoveredSending {
            do { try modelContext.save() }
            catch { modelContext.rollback(); return }
        }
        guard await healthStore.isAvailable() else { return }
        let ordered = entries
            .filter {
                ($0.state == "pending" || $0.state == "retryable")
                    && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
            }
            .sorted { $0.createdAt < $1.createdAt }

        for entry in ordered {
            if let canonicalIdentifier = HealthRepository.canonicalSyncIdentifier(
                operation: entry.operation,
                recordID: entry.recordID
            ) {
                entry.syncIdentifier = canonicalIdentifier
            }
            entry.state = "sending"
            entry.attemptCount += 1
            do { try modelContext.save() }
            catch {
                modelContext.rollback()
                return
            }

            do {
                let superseded = isSuperseded(entry, among: entries)
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

    private func writeCommand(for entry: HealthSyncOutboxEntry, in modelContext: ModelContext) throws -> HealthWriteCommand {
        if entry.operation == "upsertMeal" {
            guard let meal = try modelContext.fetch(FetchDescriptor<MealRecord>()).first(where: { $0.id == entry.recordID }) else {
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
            guard let weight = try modelContext.fetch(FetchDescriptor<WeightRecord>()).first(where: { $0.id == entry.recordID }) else {
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

    private func isSuperseded(_ entry: HealthSyncOutboxEntry, among entries: [HealthSyncOutboxEntry]) -> Bool {
        return entries.contains { candidate in
            let entryIdentifier = HealthRepository.canonicalSyncIdentifier(
                operation: entry.operation,
                recordID: entry.recordID
            ) ?? entry.syncIdentifier
            let candidateIdentifier = HealthRepository.canonicalSyncIdentifier(
                operation: candidate.operation,
                recordID: candidate.recordID
            ) ?? candidate.syncIdentifier
            return candidate.id != entry.id
                && candidate.recordID == entry.recordID
                && candidateIdentifier == entryIdentifier
                && candidate.syncVersion > entry.syncVersion
        }
    }

    private func updateActionReceipt(for entry: HealthSyncOutboxEntry, in modelContext: ModelContext, state: String) {
        guard let receiptID = entry.receiptID,
              let receipt = try? modelContext.fetch(FetchDescriptor<CommittedActionReceiptRecord>())
                .first(where: { $0.id == receiptID }) else { return }
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
