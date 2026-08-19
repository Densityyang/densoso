import CryptoKit
import DensosoDomain
import Foundation
import SwiftData

enum ConfirmationFaultPoint: String, Sendable {
    case afterRecord
    case afterProjection
    case afterOutbox
    case afterReceipt
    case afterTransactionCommitted
}

enum ConfirmationInjectedFailure: Error, Equatable {
    case fault(ConfirmationFaultPoint)
}

@ModelActor
actor SwiftDataConfirmationRepository: ConfirmationRepository {
    private var faultPoint: ConfirmationFaultPoint?

    func setFaultPoint(_ point: ConfirmationFaultPoint?) {
        faultPoint = point
    }

    func stage(
        payload: ActionPayload,
        payloadData: Data,
        canonicalPayloadData: Data,
        idempotencyKey: String,
        clientRequestID: UUID,
        createdAt: Date,
        expiresAt: Date
    ) throws -> PendingAction {
        if let existing = try pendingAction(idempotencyKey: idempotencyKey) {
            guard existing.canonicalPayloadData == canonicalPayloadData,
                  existing.clientRequestID == clientRequestID else {
                throw ConfirmationError.invariantViolation("idempotency key collision")
            }
            return try map(existing)
        }
        let record = PendingActionRecord(
            idempotencyKey: idempotencyKey,
            actionTypeRaw: payload.actionType.rawValue,
            canonicalPayloadData: canonicalPayloadData,
            payloadData: payloadData,
            clientRequestID: clientRequestID,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        modelContext.insert(record)
        try modelContext.save()
        return PendingAction(
            id: record.id,
            idempotencyKey: idempotencyKey,
            clientRequestID: clientRequestID,
            createdAt: createdAt,
            expiresAt: expiresAt,
            payload: payload,
            state: .pending
        )
    }

    func activeActions(now: Date) throws -> [PendingAction] {
        let records = try modelContext.fetch(FetchDescriptor<PendingActionRecord>())
        var changed = false
        for record in records where record.stateRaw == PendingActionState.pending.rawValue && record.expiresAt <= now {
            record.stateRaw = PendingActionState.expired.rawValue
            record.updatedAt = now
            changed = true
        }
        if changed { try modelContext.save() }
        return try records
            .filter {
                $0.stateRaw == PendingActionState.pending.rawValue
                    || $0.stateRaw == PendingActionState.committing.rawValue
            }
            .sorted { $0.createdAt < $1.createdAt }
            .map { try map($0) }
    }

    func reject(id: UUID, now: Date) throws {
        guard let action = try pendingAction(id: id) else { throw ConfirmationError.notFound }
        guard let state = PendingActionState(rawValue: action.stateRaw) else {
            throw ConfirmationError.invariantViolation("unknown pending action state \(action.stateRaw)")
        }
        if state == .pending && action.expiresAt <= now {
            action.stateRaw = PendingActionState.expired.rawValue
            action.updatedAt = now
            try modelContext.save()
            throw ConfirmationError.expired
        }
        switch state {
        case .pending:
            action.stateRaw = PendingActionState.rejected.rawValue
            action.updatedAt = now
            try modelContext.save()
        case .expired: throw ConfirmationError.expired
        case .rejected: return
        case .committing: throw ConfirmationError.alreadyCommitting
        case .committed, .failed: throw ConfirmationError.invariantViolation("cannot reject \(state.rawValue)")
        }
    }

    func confirm(id: UUID, now: Date) throws -> CommitReceipt {
        if let receipt = try receipt(actionID: id) { return try map(receipt) }
        guard let action = try pendingAction(id: id) else { throw ConfirmationError.notFound }
        guard let state = PendingActionState(rawValue: action.stateRaw) else {
            throw ConfirmationError.invariantViolation("unknown pending action state \(action.stateRaw)")
        }
        switch state {
        case .committed:
            throw ConfirmationError.invariantViolation("committed action has no receipt")
        case .rejected: throw ConfirmationError.rejected
        case .expired: throw ConfirmationError.expired
        case .failed: throw ConfirmationError.commitFailed(retryable: false)
        case .committing: throw ConfirmationError.alreadyCommitting
        case .pending: break
        }
        guard action.expiresAt > now else {
            action.stateRaw = PendingActionState.expired.rawValue
            action.updatedAt = now
            try modelContext.save()
            throw ConfirmationError.expired
        }

        let payload = try decodePayload(action.payloadData)
        guard try payload.canonicalData(schemaVersion: action.schemaVersion) == action.canonicalPayloadData else {
            throw ConfirmationError.payloadCorrupt
        }
        guard payload.actionType != .workoutPlan else { throw ConfirmationError.unsupportedAction }
        action.stateRaw = PendingActionState.committing.rawValue
        action.updatedAt = now
        try modelContext.save()

        do {
            let committedReceipt = try modelContext.transaction {
                if let existingReceipt = try receipt(actionID: id) {
                    action.stateRaw = PendingActionState.committed.rawValue
                    action.updatedAt = now
                    return try map(existingReceipt)
                }

                let localRecordID: UUID
                let affectedDate: Date
                switch payload {
                case .meal(let draft):
                    let meal = try makeMeal(from: draft, sourceActionKey: action.idempotencyKey)
                    modelContext.insert(meal)
                    localRecordID = meal.id
                    affectedDate = meal.date
                case .weight(let draft):
                    let weight = WeightRecord(
                        sourceActionKey: action.idempotencyKey,
                        measuredAt: draft.measuredAt,
                        kilograms: draft.kilograms,
                        source: draft.source
                    )
                    modelContext.insert(weight)
                    try updateProfileWeight(draft.kilograms)
                    localRecordID = weight.id
                    affectedDate = draft.measuredAt
                case .workoutPlan:
                    throw ConfirmationError.unsupportedAction
                }
                try injectFailure(.afterRecord)

                try reprojectDaily(on: affectedDate)
                try reprojectWeek(containing: affectedDate)
                try reprojectDailyHealthSnapshot(on: affectedDate)
                try injectFailure(.afterProjection)

                let outboxID = UUID()
                let outbox = HealthSyncOutboxEntry(
                    id: outboxID,
                    operation: payload.actionType == .meal ? "upsertMeal" : "upsertWeight",
                    recordID: localRecordID,
                    payloadData: action.payloadData,
                    idempotencyKey: "\(action.idempotencyKey):health-sync",
                    syncIdentifier: "densoso.\(payload.actionType.rawValue).\(localRecordID.uuidString.lowercased())"
                )
                modelContext.insert(outbox)
                try injectFailure(.afterOutbox)

                let receiptID = UUID()
                outbox.receiptID = receiptID
                let outboxIDsData = try JSONEncoder().encode([outboxID])
                let receipt = CommittedActionReceiptRecord(
                    id: receiptID,
                    actionID: action.id,
                    idempotencyKey: action.idempotencyKey,
                    actionTypeRaw: payload.actionType.rawValue,
                    localRecordID: localRecordID,
                    outboxIDsData: outboxIDsData,
                    committedAt: now
                )
                modelContext.insert(receipt)
                try injectFailure(.afterReceipt)

                action.stateRaw = PendingActionState.committed.rawValue
                action.updatedAt = now
                return try map(receipt)
            }
            try injectFailure(.afterTransactionCommitted)
            return committedReceipt
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func recoverInterruptedCommits(now: Date) throws {
        let actions = try modelContext.fetch(FetchDescriptor<PendingActionRecord>())
        var changed = false
        for action in actions where action.stateRaw == PendingActionState.committing.rawValue {
            if try receipt(actionID: action.id) != nil {
                action.stateRaw = PendingActionState.committed.rawValue
            } else if try sourceRecordExists(idempotencyKey: action.idempotencyKey, actionTypeRaw: action.actionTypeRaw) {
                action.stateRaw = PendingActionState.failed.rawValue
                action.failureCode = "record_without_receipt"
                action.failureDetail = "A source record exists without its committed receipt."
            } else if action.expiresAt <= now {
                action.stateRaw = PendingActionState.expired.rawValue
            } else {
                action.stateRaw = PendingActionState.pending.rawValue
            }
            action.updatedAt = now
            changed = true
        }

        let outboxEntries = try modelContext.fetch(FetchDescriptor<HealthSyncOutboxEntry>())
        for entry in outboxEntries where entry.state == HealthSyncState.sending.rawValue {
            entry.state = HealthSyncState.retryable.rawValue
            entry.nextAttemptAt = now
            changed = true
        }
        if changed { try modelContext.save() }
    }

    private func makeMeal(from draft: MealDraft, sourceActionKey: String) throws -> MealRecord {
        guard let total = draft.totalNutrients else { throw ConfirmationError.payloadCorrupt }
        let evidenceData = try JSONEncoder().encode(draft.dishes.flatMap(\.evidence))
        let meal = MealRecord(
            date: draft.occurredAt,
            mealType: draft.mealType,
            totalCaloriesKcal: Int(total.energyKcal.likely.rounded()),
            proteinG: total.proteinGrams?.likely ?? 0,
            fatG: total.fatGrams?.likely ?? 0,
            carbsG: total.carbohydrateGrams?.likely ?? 0,
            notes: draft.note,
            confidence: "userConfirmed",
            algorithmVersion: draft.dishes.map(\.algorithmVersion).sorted().last ?? "v3",
            sourceActionKey: sourceActionKey,
            energyLowKcal: total.energyKcal.low,
            energyLikelyKcal: total.energyKcal.likely,
            energyHighKcal: total.energyKcal.high,
            proteinLowG: total.proteinGrams?.low,
            proteinLikelyG: total.proteinGrams?.likely,
            proteinHighG: total.proteinGrams?.high,
            fatLowG: total.fatGrams?.low,
            fatLikelyG: total.fatGrams?.likely,
            fatHighG: total.fatGrams?.high,
            carbsLowG: total.carbohydrateGrams?.low,
            carbsLikelyG: total.carbohydrateGrams?.likely,
            carbsHighG: total.carbohydrateGrams?.high,
            evidenceData: evidenceData
        )
        meal.dishes = try draft.dishes.map { draftDish in
            let evidenceData = try JSONEncoder().encode(draftDish.evidence)
            let dish = DishEntry(
                id: draftDish.id,
                dishName: draftDish.name,
                cookingMethod: draftDish.cookingMethod,
                estimatedCaloriesKcal: Int(draftDish.nutrients.energyKcal.likely.rounded()),
                estimatedProteinG: draftDish.nutrients.proteinGrams?.likely ?? 0,
                estimatedFatG: draftDish.nutrients.fatGrams?.likely ?? 0,
                estimatedCarbsG: draftDish.nutrients.carbohydrateGrams?.likely ?? 0,
                confidenceScore: draftDish.evidence.compactMap(\.confidence).min() ?? 0.5,
                userCorrectionFactor: 1,
                energyLowKcal: draftDish.nutrients.energyKcal.low,
                energyLikelyKcal: draftDish.nutrients.energyKcal.likely,
                energyHighKcal: draftDish.nutrients.energyKcal.high,
                proteinLowG: draftDish.nutrients.proteinGrams?.low,
                proteinLikelyG: draftDish.nutrients.proteinGrams?.likely,
                proteinHighG: draftDish.nutrients.proteinGrams?.high,
                fatLowG: draftDish.nutrients.fatGrams?.low,
                fatLikelyG: draftDish.nutrients.fatGrams?.likely,
                fatHighG: draftDish.nutrients.fatGrams?.high,
                carbsLowG: draftDish.nutrients.carbohydrateGrams?.low,
                carbsLikelyG: draftDish.nutrients.carbohydrateGrams?.likely,
                carbsHighG: draftDish.nutrients.carbohydrateGrams?.high,
                portionLowG: draftDish.portionGrams?.low,
                portionLikelyG: draftDish.portionGrams?.likely,
                portionHighG: draftDish.portionGrams?.high,
                evidenceData: evidenceData,
                algorithmVersion: draftDish.algorithmVersion
            )
            let ingredientData = try JSONEncoder().encode(draftDish.ingredients)
            dish.ingredientJSON = String(data: ingredientData, encoding: .utf8) ?? "[]"
            return dish
        }
        return meal
    }

    private func updateProfileWeight(_ kilograms: Double) throws {
        if let profile = try modelContext.fetch(FetchDescriptor<UserProfile>()).first {
            profile.updateWeight(kilograms)
        } else {
            let profile = UserProfile(weightKg: kilograms)
            profile.updateWeight(kilograms)
            modelContext.insert(profile)
        }
    }

    private func reprojectDaily(on date: Date) throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let meals = try modelContext.fetch(FetchDescriptor<MealRecord>()).filter { $0.date >= day && $0.date < nextDay }
        let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>()).filter { $0.date >= day && $0.date < nextDay }
        let profile = try modelContext.fetch(FetchDescriptor<UserProfile>()).first ?? UserProfile()
        let projected = CaloricEngine.computeDailyMetrics(date: day, meals: meals, workouts: workouts, userProfile: profile)
        if let existing = try modelContext.fetch(FetchDescriptor<DailyMetrics>()).first(where: { $0.date == day }) {
            existing.bmrKcal = projected.bmrKcal
            existing.activeCaloriesKcal = projected.activeCaloriesKcal
            existing.totalExpenditureKcal = projected.totalExpenditureKcal
            existing.totalIntakeKcal = projected.totalIntakeKcal
            existing.deficitKcal = projected.deficitKcal
            existing.proteinG = projected.proteinG
            existing.fatG = projected.fatG
            existing.carbsG = projected.carbsG
            existing.mealCount = projected.mealCount
            existing.workoutCount = projected.workoutCount
            existing.computedAt = projected.computedAt
        } else {
            modelContext.insert(projected)
        }
    }

    private func reprojectWeek(containing date: Date) throws {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return }
        let weekStart = calendar.startOfDay(for: interval.start)
        let metrics = try modelContext.fetch(FetchDescriptor<DailyMetrics>())
            .filter { $0.date >= interval.start && $0.date < interval.end }
        let profile = try modelContext.fetch(FetchDescriptor<UserProfile>()).first
        let target = max(profile?.dailyDeficitTarget ?? 500, 0)
        let existing = try modelContext.fetch(FetchDescriptor<WeeklyReport>())
            .first(where: { $0.weekStartDate == weekStart })
        let report = existing
            ?? WeeklyReport(weekStartDate: weekStart, weekEndDate: interval.end.addingTimeInterval(-1))
        if existing == nil { modelContext.insert(report) }
        let count = metrics.count
        let totalDeficit = metrics.reduce(0) { $0 + $1.deficitKcal }
        report.weekEndDate = interval.end.addingTimeInterval(-1)
        report.totalDeficitKcal = totalDeficit
        report.avgDailyDeficitKcal = count == 0 ? 0 : Double(totalDeficit) / Double(count)
        report.projectedWeightLossKg = Double(totalDeficit) / 7_700
        report.avgProteinG = average(metrics.map(\.proteinG))
        report.avgFatG = average(metrics.map(\.fatG))
        report.avgCarbsG = average(metrics.map(\.carbsG))
        report.bestDay = metrics.max(by: { $0.deficitKcal < $1.deficitKcal })?.date
        report.worstDay = metrics.min(by: { $0.deficitKcal < $1.deficitKcal })?.date
        report.mealsCount = metrics.reduce(0) { $0 + $1.mealCount }
        report.workoutsCount = metrics.reduce(0) { $0 + $1.workoutCount }
        report.compliance = count == 0 ? 0 : Double(metrics.filter { $0.deficitKcal >= target }.count) / Double(count)
        report.generatedAt = Date()
    }

    private func reprojectDailyHealthSnapshot(on date: Date) throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let meals = try modelContext.fetch(FetchDescriptor<MealRecord>())
            .filter { $0.date >= day && $0.date < nextDay }
        let weights = try modelContext.fetch(FetchDescriptor<WeightRecord>())
            .filter { $0.measuredAt >= day && $0.measuredAt < nextDay }
            .sorted { $0.measuredAt < $1.measuredAt }
        let metrics = try modelContext.fetch(FetchDescriptor<DailyMetrics>())
            .first(where: { $0.date == day })

        let intakeRange: EstimateRange?
        if meals.isEmpty {
            intakeRange = nil
        } else {
            intakeRange = try EstimateRange.sum(
                meals.map {
                    try EstimateRange(
                        low: $0.energyLowKcal,
                        likely: $0.energyLikelyKcal,
                        high: $0.energyHighKcal
                    )
                }
            )
        }
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            energyIntakeKcal: intakeRange,
            activeEnergyKcal: metrics.map { Double($0.activeCaloriesKcal) },
            weightKilograms: weights.last?.kilograms,
            algorithmVersion: "v3"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(snapshot)
        let snapshotHash = SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
        if let existing = try modelContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .first(where: { $0.dayKey == dayKey }) {
            existing.timezoneID = calendar.timeZone.identifier
            existing.payloadData = payloadData
            existing.snapshotHash = snapshotHash
            existing.algorithmVersion = "v3"
        } else {
            modelContext.insert(
                DailyHealthSnapshotRecord(
                    dayKey: dayKey,
                    timezoneID: calendar.timeZone.identifier,
                    payloadData: payloadData,
                    snapshotHash: snapshotHash,
                    algorithmVersion: "v3"
                )
            )
        }
    }

    private func pendingAction(id: UUID) throws -> PendingActionRecord? {
        try modelContext.fetch(FetchDescriptor<PendingActionRecord>()).first { $0.id == id }
    }

    private func pendingAction(idempotencyKey: String) throws -> PendingActionRecord? {
        try modelContext.fetch(FetchDescriptor<PendingActionRecord>()).first { $0.idempotencyKey == idempotencyKey }
    }

    private func receipt(actionID: UUID) throws -> CommittedActionReceiptRecord? {
        try modelContext.fetch(FetchDescriptor<CommittedActionReceiptRecord>()).first { $0.actionID == actionID }
    }

    private func sourceRecordExists(idempotencyKey: String, actionTypeRaw: String) throws -> Bool {
        switch ActionType(rawValue: actionTypeRaw) {
        case .meal:
            return try modelContext.fetch(FetchDescriptor<MealRecord>()).contains { $0.sourceActionKey == idempotencyKey }
        case .weight:
            return try modelContext.fetch(FetchDescriptor<WeightRecord>()).contains { $0.sourceActionKey == idempotencyKey }
        case .workoutPlan:
            return false
        case nil:
            throw ConfirmationError.invariantViolation("unknown action type \(actionTypeRaw)")
        }
    }

    private func decodePayload(_ data: Data) throws -> ActionPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let payload = try? decoder.decode(ActionPayload.self, from: data) else {
            throw ConfirmationError.payloadCorrupt
        }
        return payload
    }

    private func map(_ record: PendingActionRecord) throws -> PendingAction {
        guard let state = PendingActionState(rawValue: record.stateRaw) else {
            throw ConfirmationError.invariantViolation("unknown pending action state \(record.stateRaw)")
        }
        return PendingAction(
            id: record.id,
            idempotencyKey: record.idempotencyKey,
            clientRequestID: record.clientRequestID,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt,
            payload: try decodePayload(record.payloadData),
            state: state,
            failureCode: record.failureCode
        )
    }

    private func map(_ record: CommittedActionReceiptRecord) throws -> CommitReceipt {
        guard let actionType = ActionType(rawValue: record.actionTypeRaw),
              let syncState = HealthSyncState(rawValue: record.healthSyncStateRaw),
              let outboxIDs = try? JSONDecoder().decode([UUID].self, from: record.outboxIDsData) else {
            throw ConfirmationError.invariantViolation("receipt payload is invalid")
        }
        return CommitReceipt(
            id: record.id,
            actionID: record.actionID,
            idempotencyKey: record.idempotencyKey,
            actionType: actionType,
            localRecordID: record.localRecordID,
            outboxIDs: outboxIDs,
            committedAt: record.committedAt,
            healthSyncState: syncState
        )
    }

    private func injectFailure(_ point: ConfirmationFaultPoint) throws {
        if faultPoint == point { throw ConfirmationInjectedFailure.fault(point) }
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

}
