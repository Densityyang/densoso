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
    static let expiredActionBatchSize = 64
    static let activeActionBatchSize = 64
    static let recoveryBatchSize = 64

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
        let pendingState = PendingActionState.pending.rawValue
        let committingState = PendingActionState.committing.rawValue
        let expiredState = PendingActionState.expired.rawValue
        let expirationSort = [
            SortDescriptor(\PendingActionRecord.createdAt),
            SortDescriptor(\PendingActionRecord.idempotencyKey),
        ]
        while true {
            let expiredPredicate = #Predicate<PendingActionRecord> {
                $0.stateRaw == pendingState && $0.expiresAt <= now
            }
            var expiredDescriptor = FetchDescriptor<PendingActionRecord>(
                predicate: expiredPredicate,
                sortBy: expirationSort
            )
            expiredDescriptor.fetchLimit = Self.expiredActionBatchSize
            let expiredRecords = try modelContext.fetch(expiredDescriptor)
            guard !expiredRecords.isEmpty else { break }
            for record in expiredRecords {
                record.stateRaw = expiredState
                record.updatedAt = now
            }
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        let activePredicate = #Predicate<PendingActionRecord> {
            ($0.stateRaw == pendingState && $0.expiresAt > now)
                || $0.stateRaw == committingState
        }
        let activeSort = [
            SortDescriptor(\PendingActionRecord.createdAt),
            SortDescriptor(\PendingActionRecord.idempotencyKey),
        ]
        var actions: [PendingAction] = []
        var cursorCreatedAt: Date?
        var cursorIdempotencyKey: String?

        while true {
            let pagePredicate: Predicate<PendingActionRecord>
            if let cursorCreatedAt, let cursorIdempotencyKey {
                let cursorDate = cursorCreatedAt
                let cursorKey = cursorIdempotencyKey
                pagePredicate = #Predicate<PendingActionRecord> { record in
                    ((record.stateRaw == pendingState && record.expiresAt > now)
                        || record.stateRaw == committingState)
                        && (record.createdAt > cursorDate
                            || (record.createdAt == cursorDate && record.idempotencyKey > cursorKey))
                }
            } else {
                pagePredicate = activePredicate
            }

            var activeDescriptor = FetchDescriptor<PendingActionRecord>(
                predicate: pagePredicate,
                sortBy: activeSort
            )
            activeDescriptor.fetchLimit = Self.activeActionBatchSize
            let page = try modelContext.fetch(activeDescriptor)
            guard !page.isEmpty else { break }
            actions.append(contentsOf: try page.map { try map($0) })
            guard let last = page.last else { break }
            cursorCreatedAt = last.createdAt
            cursorIdempotencyKey = last.idempotencyKey
            if page.count < Self.activeActionBatchSize { break }
        }
        return actions
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
        action.stateRaw = PendingActionState.committing.rawValue
        action.updatedAt = now
        try modelContext.save()

        do {
            var committedReceipt: CommitReceipt?
            try modelContext.transaction {
                if let existingReceipt = try receipt(actionID: id) {
                    action.stateRaw = PendingActionState.committed.rawValue
                    action.updatedAt = now
                    committedReceipt = try map(existingReceipt)
                    return
                }

                let localRecordID: UUID
                var affectedDate: Date?
                var outboxIDs: [UUID] = []
                var healthSyncState = HealthSyncState.notApplicable
                switch payload {
                case .meal(let draft):
                    let meal = try makeMeal(from: draft, sourceActionKey: action.idempotencyKey)
                    modelContext.insert(meal)
                    localRecordID = meal.id
                    affectedDate = meal.date
                    healthSyncState = .pending
                case .weight(let draft):
                    let weight = WeightRecord(
                        sourceActionKey: action.idempotencyKey,
                        measuredAt: draft.measuredAt,
                        kilograms: draft.kilograms,
                        source: draft.source
                    )
                    modelContext.insert(weight)
                    try updateProfileWeight(draft.kilograms, measuredAt: draft.measuredAt)
                    localRecordID = weight.id
                    affectedDate = draft.measuredAt
                    healthSyncState = .pending
                case .workoutPlan(let draft):
                    try WorkoutPlanCompiler().validate(draft)
                    guard let scheduledAt = draft.scheduledAt else {
                        throw WorkoutPlanCompileError.scheduleDateRequired
                    }
                    let entry = ConfirmedWorkoutPlanEntry(
                        actionID: action.id,
                        idempotencyKey: action.idempotencyKey,
                        draft: draft
                    )
                    let estimatedEnd: Date?
                    if case .timeMinutes(let minutes) = draft.goal {
                        estimatedEnd = scheduledAt.addingTimeInterval(Double(minutes) * 60)
                    } else {
                        estimatedEnd = nil
                    }
                    modelContext.insert(ScheduleEvent(
                        date: scheduledAt,
                        title: draft.name,
                        notes: try entry.encodedNotes(),
                        startTime: scheduledAt,
                        endTime: estimatedEnd
                    ))
                    // A plan receipt refers to its action; it is not a completed Workout record.
                    localRecordID = action.id
                    affectedDate = nil
                case .trainingPlan(let draft):
                    let compiled = try TrainingPlanCompiler().compile(draft)
                    guard let firstSession = draft.sessions.min(by: { $0.date < $1.date }) else {
                        throw TrainingPlanCompileError.invalidDraft(.invalidSessionCount)
                    }
                    let entry = ConfirmedTrainingPlanEntry(
                        actionID: action.id,
                        idempotencyKey: action.idempotencyKey,
                        draft: draft
                    )
                    modelContext.insert(ScheduleEvent(
                        date: firstSession.date,
                        title: compiled.name,
                        notes: try entry.encodedNotes(),
                        startTime: firstSession.date,
                        endTime: nil
                    ))
                    // One app-owned plan record represents all sessions; none is a completed Workout.
                    localRecordID = action.id
                    affectedDate = nil
                    healthSyncState = .notApplicable
                case .dailyCheckIn(let checkIn):
                    let record = DailyCheckInRecord(
                        sourceActionKey: action.idempotencyKey,
                        occurredAt: checkIn.occurredAt,
                        energyRaw: checkIn.energy.rawValue,
                        stressRaw: checkIn.stress.rawValue,
                        subjectiveSleepRaw: checkIn.subjectiveSleep.rawValue,
                        note: checkIn.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        sourceRaw: "userReported"
                    )
                    modelContext.insert(record)
                    localRecordID = record.id
                    // User-reported check-ins remain separate from objective daily projections.
                    affectedDate = nil
                    healthSyncState = .notApplicable
                case .userPreference(let preference):
                    let record = UserPreferenceRecord(
                        id: preference.id,
                        sourceActionKey: action.idempotencyKey,
                        categoryRaw: preference.category.rawValue,
                        statement: preference.statement.trimmingCharacters(in: .whitespacesAndNewlines),
                        sourceRaw: preference.source.rawValue,
                        createdAt: preference.createdAt
                    )
                    modelContext.insert(record)
                    localRecordID = record.id
                    // Preferences are local user-reported facts, not HealthKit data or projections.
                    affectedDate = nil
                    healthSyncState = .notApplicable
                }
                try injectFailure(.afterRecord)

                if let affectedDate {
                    try reprojectDaily(on: affectedDate)
                    try reprojectWeek(containing: affectedDate)
                    try reprojectDailyHealthSnapshot(on: affectedDate)
                }
                try injectFailure(.afterProjection)

                let outbox: HealthSyncOutboxEntry?
                if payload.actionType == .workoutPlan
                    || payload.actionType == .trainingPlan
                    || payload.actionType == .dailyCheckIn
                    || payload.actionType == .userPreference {
                    outbox = nil
                } else {
                    let outboxID = UUID()
                    outbox = HealthSyncOutboxEntry(
                        id: outboxID,
                        operation: payload.actionType == .meal ? "upsertMeal" : "upsertWeight",
                        recordID: localRecordID,
                        payloadData: action.payloadData,
                        idempotencyKey: "\(action.idempotencyKey):health-sync",
                        syncIdentifier: "densoso.\(payload.actionType.rawValue).\(localRecordID.uuidString.lowercased())"
                    )
                    if let outbox {
                        modelContext.insert(outbox)
                    }
                    outboxIDs.append(outboxID)
                }
                try injectFailure(.afterOutbox)

                let receiptID = UUID()
                outbox?.receiptID = receiptID
                let outboxIDsData = try JSONEncoder().encode(outboxIDs)
                let receipt = CommittedActionReceiptRecord(
                    id: receiptID,
                    actionID: action.id,
                    idempotencyKey: action.idempotencyKey,
                    actionTypeRaw: payload.actionType.rawValue,
                    localRecordID: localRecordID,
                    outboxIDsData: outboxIDsData,
                    committedAt: now,
                    healthSyncStateRaw: healthSyncState.rawValue
                )
                modelContext.insert(receipt)
                try injectFailure(.afterReceipt)

                action.stateRaw = PendingActionState.committed.rawValue
                action.updatedAt = now
                committedReceipt = try map(receipt)
            }
            guard let committedReceipt else {
                throw ConfirmationError.invariantViolation("transaction completed without a receipt")
            }
            try injectFailure(.afterTransactionCommitted)
            return committedReceipt
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func recoverInterruptedCommits(now: Date) throws {
        let committingState = PendingActionState.committing.rawValue
        var changed = false
        let committingSort = [
            SortDescriptor(\PendingActionRecord.createdAt),
            SortDescriptor(\PendingActionRecord.id),
        ]
        var actionCursorCreatedAt: Date?
        var actionCursorID: UUID?
        while true {
            let committingPredicate: Predicate<PendingActionRecord>
            if let actionCursorCreatedAt, let actionCursorID {
                let cursorCreatedAt = actionCursorCreatedAt
                let cursorID = actionCursorID
                committingPredicate = #Predicate<PendingActionRecord> { action in
                    action.stateRaw == committingState
                        && (action.createdAt > cursorCreatedAt
                            || (action.createdAt == cursorCreatedAt && action.id > cursorID))
                }
            } else {
                committingPredicate = #Predicate<PendingActionRecord> {
                    $0.stateRaw == committingState
                }
            }
            var actionDescriptor = FetchDescriptor<PendingActionRecord>(
                predicate: committingPredicate,
                sortBy: committingSort
            )
            actionDescriptor.fetchLimit = Self.recoveryBatchSize
            let actions = try modelContext.fetch(actionDescriptor)
            guard let lastAction = actions.last else { break }
            for action in actions {
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
            actionCursorCreatedAt = lastAction.createdAt
            actionCursorID = lastAction.id
            if actions.count < Self.recoveryBatchSize { break }
        }

        let sendingState = HealthSyncState.sending.rawValue
        let sendingSort = [
            SortDescriptor(\HealthSyncOutboxEntry.createdAt),
            SortDescriptor(\HealthSyncOutboxEntry.idempotencyKey),
        ]
        var outboxCursorCreatedAt: Date?
        var outboxCursorIdempotencyKey: String?
        while true {
            let sendingPredicate: Predicate<HealthSyncOutboxEntry>
            if let outboxCursorCreatedAt, let outboxCursorIdempotencyKey {
                let cursorCreatedAt = outboxCursorCreatedAt
                let cursorKey = outboxCursorIdempotencyKey
                sendingPredicate = #Predicate<HealthSyncOutboxEntry> { entry in
                    entry.state == sendingState
                        && (entry.createdAt > cursorCreatedAt
                            || (entry.createdAt == cursorCreatedAt && entry.idempotencyKey > cursorKey))
                }
            } else {
                sendingPredicate = #Predicate<HealthSyncOutboxEntry> { $0.state == sendingState }
            }
            var outboxDescriptor = FetchDescriptor<HealthSyncOutboxEntry>(
                predicate: sendingPredicate,
                sortBy: sendingSort
            )
            outboxDescriptor.fetchLimit = Self.recoveryBatchSize
            let outboxEntries = try modelContext.fetch(outboxDescriptor)
            guard let lastEntry = outboxEntries.last else { break }
            for entry in outboxEntries {
                entry.state = HealthSyncState.retryable.rawValue
                entry.nextAttemptAt = now
                changed = true
            }
            outboxCursorCreatedAt = lastEntry.createdAt
            outboxCursorIdempotencyKey = lastEntry.idempotencyKey
            if outboxEntries.count < Self.recoveryBatchSize { break }
        }
        if changed { try modelContext.save() }
    }

    private func makeMeal(from draft: MealDraft, sourceActionKey: String) throws -> MealRecord {
        guard let total = draft.totalNutrients else { throw ConfirmationError.payloadCorrupt }
        let evidenceData = try JSONEncoder().encode(draft.dishes.flatMap(\.evidence))
        // V3 scalar macros are non-optional compatibility mirrors; nil means
        // unknown, not zero. Optional range fields and evidenceData are canonical.
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

    private func updateProfileWeight(_ kilograms: Double, measuredAt: Date) throws {
        let primaryProfileKey = "primary"
        let predicate = #Predicate<UserProfile> { $0.profileKey == primaryProfileKey }
        var descriptor = FetchDescriptor<UserProfile>(predicate: predicate)
        descriptor.fetchLimit = 1
        let profile: UserProfile
        if let existing = try modelContext.fetch(descriptor).first {
            profile = existing
        } else {
            profile = UserProfile(weightKg: kilograms)
            modelContext.insert(profile)
        }

        guard measuredAt >= profile.updatedAt else { return }
        let now = Date()
        profile.weightKg = kilograms
        profile.updatedAt = now
        profile.profileNeedsCompletion = profile.dateOfBirth == nil
        modelContext.insert(
            ProfileRevisionRecord(
                profileKey: profile.profileKey,
                effectiveFrom: now,
                dateOfBirth: profile.dateOfBirth,
                biologicalSex: profile.biologicalSex,
                heightCm: profile.heightCm,
                weightKg: kilograms,
                activityLevel: profile.activityLevel,
                source: "userEdited",
                createdAt: now
            )
        )
    }

    private func reprojectDaily(on date: Date) throws {
        // Keep this projection inside the ModelActor transaction. The standalone
        // DailyMetricsProjector is MainActor-isolated and cannot be awaited here.
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let projectionInputs = try DailyMetricsProjectionInputReader.read(on: day, in: modelContext)
        let primaryProfileKey = "primary"
        let profilePredicate = #Predicate<UserProfile> { $0.profileKey == primaryProfileKey }
        var profileDescriptor = FetchDescriptor<UserProfile>(predicate: profilePredicate)
        profileDescriptor.fetchLimit = 1
        let profileKey = try modelContext.fetch(profileDescriptor).first?.profileKey ?? primaryProfileKey
        let effectiveRevision = try EffectiveProfileRevisionReader.latest(
            in: modelContext,
            profileKey: profileKey,
            effectiveAt: day
        )
        let effectiveProfile: EffectiveProfile?
        if let effectiveRevision {
            effectiveProfile = EffectiveProfileResolver(
                profileKey: profileKey,
                revisions: [domainRevision(effectiveRevision)]
            ).profile(at: day)
        } else {
            effectiveProfile = nil
        }
        let localWeight = try LocalWeightObservationReader.latestObservation(in: modelContext, effectiveAt: day)
        let healthKitWeight = try HealthKitWeightObservationReader.latestObservation(in: modelContext, effectiveAt: day)
        let weightObservations = [localWeight, healthKitWeight].compactMap { $0 }
        let effectiveWeight = WeightTimeline(observations: weightObservations).effectiveWeight(
            at: day,
            profileWeightKg: effectiveRevision?.weightKg,
            profileEffectiveFrom: effectiveRevision?.effectiveFrom
        )
        let targetDayKey = dayKey(for: day)
        let snapshotPredicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == targetDayKey }
        var snapshotDescriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: snapshotPredicate)
        snapshotDescriptor.fetchLimit = 1
        let snapshotRecord = try modelContext.fetch(snapshotDescriptor).first
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let healthSnapshot = try snapshotRecord.map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        let projected = CaloricEngine.computeDailyMetrics(
            date: day,
            meals: projectionInputs.meals,
            workouts: projectionInputs.workouts,
            effectiveProfile: effectiveProfile,
            effectiveWeight: effectiveWeight,
            healthKitActiveEnergyKcal: healthSnapshot?.activeEnergyForProjection,
            healthKitRestingEnergyKcal: healthSnapshot?.restingEnergyForProjection,
            healthKitSteps: healthSnapshot?.stepCountForProjection,
            healthKitExerciseMinutes: healthSnapshot?.exerciseMinutesForProjection
        )
        let metricsPredicate = #Predicate<DailyMetrics> { $0.date == day }
        var metricsDescriptor = FetchDescriptor<DailyMetrics>(predicate: metricsPredicate)
        metricsDescriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(metricsDescriptor).first {
            copyProjectedMetrics(projected, to: existing)
        } else {
            modelContext.insert(projected)
        }
    }

    private func domainRevision(_ record: ProfileRevisionRecord) -> ProfileRevision {
        ProfileRevision(
            id: record.id,
            profileKey: record.profileKey,
            effectiveFrom: record.effectiveFrom,
            dateOfBirth: record.dateOfBirth,
            biologicalSex: BiologicalSex(rawValue: record.biologicalSex) ?? .unspecified,
            heightCm: record.heightCm,
            weightKg: record.weightKg,
            activityLevel: ActivityLevel(rawValue: record.activityLevel) ?? .unspecified,
            source: ProfileSource(rawValue: record.source) ?? .legacyMigration,
            createdAt: record.createdAt
        )
    }

    private func healthKitWeightObservations(effectiveAt day: Date) throws -> [WeightObservation] {
        try HealthKitWeightObservationReader.latestObservation(in: modelContext, effectiveAt: day)
            .map { [$0] } ?? []
    }

    private func dayKey(for day: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func copyProjectedMetrics(_ source: DailyMetrics, to destination: DailyMetrics) {
        destination.bmrKcal = source.bmrKcal
        destination.activeCaloriesKcal = source.activeCaloriesKcal
        destination.totalExpenditureKcal = source.totalExpenditureKcal
        destination.totalIntakeKcal = source.totalIntakeKcal
        destination.deficitKcal = source.deficitKcal
        destination.proteinG = source.proteinG
        destination.fatG = source.fatG
        destination.carbsG = source.carbsG
        destination.mealCount = source.mealCount
        destination.workoutCount = source.workoutCount
        destination.computedAt = source.computedAt
        destination.intakeEnergyLowKcal = source.intakeEnergyLowKcal
        destination.intakeEnergyLikelyKcal = source.intakeEnergyLikelyKcal
        destination.intakeEnergyHighKcal = source.intakeEnergyHighKcal
        destination.expenditureEnergyLowKcal = source.expenditureEnergyLowKcal
        destination.expenditureEnergyLikelyKcal = source.expenditureEnergyLikelyKcal
        destination.expenditureEnergyHighKcal = source.expenditureEnergyHighKcal
        destination.energyBalanceLowKcal = source.energyBalanceLowKcal
        destination.energyBalanceLikelyKcal = source.energyBalanceLikelyKcal
        destination.energyBalanceHighKcal = source.energyBalanceHighKcal
        destination.activeEnergyKcal = source.activeEnergyKcal
        destination.basalEnergyKcal = source.basalEnergyKcal
        destination.steps = source.steps
        destination.exerciseMinutes = source.exerciseMinutes
        destination.weightKg = source.weightKg
        destination.energyQuality = source.energyQuality
        destination.dataCoverageJSON = source.dataCoverageJSON
        destination.projectionVersion = source.projectionVersion
        destination.sourceFingerprint = source.sourceFingerprint
        destination.requiresRecompute = source.requiresRecompute
    }

    private func reprojectWeek(containing date: Date) throws {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { return }
        let weekStart = calendar.startOfDay(for: interval.start)
        let metricsPredicate = #Predicate<DailyMetrics> {
            $0.date >= interval.start && $0.date < interval.end
        }
        let metrics = try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: metricsPredicate))
        let profile = try modelContext.fetch(FetchDescriptor<UserProfile>()).first
        let target = max(profile?.dailyDeficitTarget ?? 500, 0)
        let reportPredicate = #Predicate<WeeklyReport> { $0.weekStartDate == weekStart }
        var reportDescriptor = FetchDescriptor<WeeklyReport>(predicate: reportPredicate)
        reportDescriptor.fetchLimit = 1
        let existing = try modelContext.fetch(reportDescriptor).first
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
        let meals = try DailyMetricsProjectionInputReader.meals(on: day, in: modelContext)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let weightPredicate = #Predicate<WeightRecord> {
            $0.measuredAt >= day && $0.measuredAt < nextDay
        }
        var weightDescriptor = FetchDescriptor<WeightRecord>(
            predicate: weightPredicate,
            sortBy: [
                SortDescriptor(\WeightRecord.measuredAt, order: .reverse),
                SortDescriptor(\WeightRecord.id, order: .reverse),
            ]
        )
        weightDescriptor.fetchLimit = 1
        let latestWeight = try modelContext.fetch(weightDescriptor).first?.kilograms
        let targetDayKey = dayKey(for: day)
        let snapshotPredicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == targetDayKey }
        var snapshotDescriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: snapshotPredicate)
        snapshotDescriptor.fetchLimit = 1
        let existingRecord = try modelContext.fetch(snapshotDescriptor).first
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let existingSnapshot = try existingRecord.map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }

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
            activeEnergyKcal: existingSnapshot?.activeEnergyKcal,
            restingEnergyKcal: existingSnapshot?.restingEnergyKcal,
            stepCount: existingSnapshot?.stepCount,
            exerciseMinutes: existingSnapshot?.exerciseMinutes,
            weightKilograms: latestWeight ?? existingSnapshot?.weightKilograms,
            healthKitSampleSummary: existingSnapshot?.healthKitSampleSummary,
            healthReadStates: existingSnapshot?.healthReadStates,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(snapshot)
        let snapshotHash = SHA256.hash(data: payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        let existingPredicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == targetDayKey }
        var existingDescriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: existingPredicate)
        existingDescriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(existingDescriptor).first {
            existing.timezoneID = calendar.timeZone.identifier
            existing.payloadData = payloadData
            existing.snapshotHash = snapshotHash
            existing.algorithmVersion = DailyHealthSnapshot.currentAlgorithmVersion
        } else {
            modelContext.insert(
                DailyHealthSnapshotRecord(
                    dayKey: targetDayKey,
                    timezoneID: calendar.timeZone.identifier,
                    payloadData: payloadData,
                    snapshotHash: snapshotHash,
                    algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
                )
            )
        }
    }

    private func pendingAction(id: UUID) throws -> PendingActionRecord? {
        let predicate = #Predicate<PendingActionRecord> { $0.id == id }
        var descriptor = FetchDescriptor<PendingActionRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func pendingAction(idempotencyKey: String) throws -> PendingActionRecord? {
        let predicate = #Predicate<PendingActionRecord> { $0.idempotencyKey == idempotencyKey }
        var descriptor = FetchDescriptor<PendingActionRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func receipt(actionID: UUID) throws -> CommittedActionReceiptRecord? {
        let predicate = #Predicate<CommittedActionReceiptRecord> { $0.actionID == actionID }
        var descriptor = FetchDescriptor<CommittedActionReceiptRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func sourceRecordExists(idempotencyKey: String, actionTypeRaw: String) throws -> Bool {
        switch ActionType(rawValue: actionTypeRaw) {
        case .meal:
            let predicate = #Predicate<MealRecord> { $0.sourceActionKey == idempotencyKey }
            var descriptor = FetchDescriptor<MealRecord>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try !modelContext.fetch(descriptor).isEmpty
        case .weight:
            let predicate = #Predicate<WeightRecord> { $0.sourceActionKey == idempotencyKey }
            var descriptor = FetchDescriptor<WeightRecord>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try !modelContext.fetch(descriptor).isEmpty
        case .workoutPlan:
            return try scheduleEvents(containingNotesPrefix: ConfirmedWorkoutPlanEntry.notesPrefix).contains { event in
                ConfirmedWorkoutPlanEntry.decode(notes: event.notes)?.idempotencyKey == idempotencyKey
            }
        case .trainingPlan:
            return try scheduleEvents(containingNotesPrefix: ConfirmedTrainingPlanEntry.notesPrefix).contains { event in
                ConfirmedTrainingPlanEntry.decode(notes: event.notes)?.idempotencyKey == idempotencyKey
            }
        case .dailyCheckIn:
            let predicate = #Predicate<DailyCheckInRecord> { $0.sourceActionKey == idempotencyKey }
            var descriptor = FetchDescriptor<DailyCheckInRecord>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try !modelContext.fetch(descriptor).isEmpty
        case .userPreference:
            let predicate = #Predicate<UserPreferenceRecord> { $0.sourceActionKey == idempotencyKey }
            var descriptor = FetchDescriptor<UserPreferenceRecord>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try !modelContext.fetch(descriptor).isEmpty
        case nil:
            throw ConfirmationError.invariantViolation("unknown action type \(actionTypeRaw)")
        }
    }

    private func scheduleEvents(containingNotesPrefix prefix: String) throws -> [ScheduleEvent] {
        let predicate = #Predicate<ScheduleEvent> { $0.notes?.contains(prefix) == true }
        return try modelContext.fetch(FetchDescriptor<ScheduleEvent>(predicate: predicate))
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
