import Foundation
import DensosoDomain
import SwiftData

@ModelActor
actor SwiftDataAgentRepository: AgentReadRepository, ConversationRepository {
    static let dailyMetricFetchBatchSize = 64
    static let messageFetchBatchSize = 64
    static let userPreferenceFetchBatchSize = 64
    static let scheduleEventFetchBatchSize = 64
    static let conversationResetBatchSize = 64
    static let recentWorkoutFetchBatchSize = 64

    private struct UserPreferenceCursor {
        let createdAt: Date
        let sourceActionKey: String
    }

    private struct UserPreferenceCandidate {
        let record: UserPreferenceRecord
        let category: UserPreferenceCategory
        let statement: String
    }

    private struct MessageCursor {
        let ordinal: Int
        let id: UUID
    }

    func beginAgentRequest(
        requestID: UUID,
        conversationID: UUID,
        initialBudget: AgentBudget,
        startedAt: Date,
        containsTransientImage: Bool
    ) throws -> AgentRequestSnapshot {
        try ensureConversation(id: conversationID)
        let descriptor = FetchDescriptor<AgentRequestRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            guard existing.conversationID == conversationID else {
                throw AgentRequestPersistenceError.conversationMismatch
            }
            if existing.containsTransientImage && !containsTransientImage {
                // Do not consume a resume or reset state when the original
                // transient media has not been reattached by the user.
                return try requestSnapshot(existing)
            }
            guard existing.containsTransientImage == containsTransientImage else {
                throw AgentRequestPersistenceError.requestMediaMismatch
            }
            try ensureCostBudgetRecord(
                for: existing,
                fallbackMaximumCostMicros: AgentBudget.defaultMaximumCostMicros
            )
            let state = try requestState(existing)
            if state == .running || state == .interrupted {
                existing.resumeCount = existing.resumeCount == Int.max ? Int.max : existing.resumeCount + 1
                existing.stateRaw = AgentRequestState.running.rawValue
                existing.updatedAt = Date()
                try modelContext.save()
            }
            return try requestSnapshot(existing)
        }

        let record = AgentRequestRecord(
            requestID: requestID,
            conversationID: conversationID,
            startedAt: startedAt,
            absoluteDeadline: initialBudget.deadline,
            maximumProviderRounds: initialBudget.maximumProviderRounds,
            maximumToolCalls: initialBudget.maximumToolCalls,
            containsTransientImage: containsTransientImage
        )
        modelContext.insert(record)
        modelContext.insert(AgentRequestCostBudgetRecord(
            requestID: requestID,
            conversationID: conversationID,
            maximumCostMicros: initialBudget.maximumCostMicros
        ))
        try modelContext.save()
        return try requestSnapshot(record)
    }

    func updateAgentRequestConsumption(
        requestID: UUID,
        conversationID: UUID,
        consumption: AgentBudgetConsumption
    ) throws {
        let record = try fetchAgentRequest(requestID: requestID, conversationID: conversationID)
        record.providerRoundsUsed = consumption.providerRoundsUsed
        record.toolCallsUsed = consumption.toolCallsUsed
        record.inputTokens = consumption.inputTokens
        record.cachedInputTokens = consumption.cachedInputTokens
        record.outputTokens = consumption.outputTokens
        record.reasoningTokens = consumption.reasoningTokens
        record.updatedAt = Date()
        try modelContext.save()
    }

    func reserveAgentRequestCost(
        requestID: UUID,
        conversationID: UUID,
        provider: ProviderID,
        model: String,
        currency: String,
        pricingVersion: String,
        providerRound: Int,
        estimatedCostMicros: Int64?
    ) throws -> AgentRequestCostBudget {
        guard providerRound > 0, estimatedCostMicros.map({ $0 >= 0 }) ?? true else {
            throw AgentRequestPersistenceError.costBudgetMismatch
        }
        _ = try fetchAgentRequest(requestID: requestID, conversationID: conversationID)
        let record = try fetchCostBudgetRecord(requestID: requestID, conversationID: conversationID)
        let budgetState = AgentCostBudgetState(rawValue: record.costStateRaw) ?? .unavailable
        if record.providerRaw != "unresolved",
           (record.providerRaw != provider.rawValue || record.model != model) {
            throw AgentRequestPersistenceError.costBudgetMismatch
        }
        if budgetState == .unavailable {
            guard record.providerRaw != "unresolved" else {
                throw AgentRequestPersistenceError.costBudgetMismatch
            }
            return costBudgetSnapshot(record)
        }
        if budgetState == .estimated {
            guard record.providerRaw != "unresolved" else {
                throw AgentRequestPersistenceError.costBudgetMismatch
            }
            if currency != record.currency || pricingVersion != record.pricingVersion || estimatedCostMicros == nil {
                record.costStateRaw = AgentCostBudgetState.unavailable.rawValue
                record.updatedAt = Date()
                try modelContext.save()
                return costBudgetSnapshot(record)
            }
            guard record.reservedCostMicros <= record.maximumCostMicros else {
                throw AgentRequestPersistenceError.costBudgetExceeded
            }
            if record.lastReservedProviderRound == providerRound {
                return costBudgetSnapshot(record)
            }
        }
        if estimatedCostMicros == nil {
            record.providerRaw = provider.rawValue
            record.model = model
            record.currency = "unavailable"
            record.pricingVersion = "unknown"
            record.lastReservedProviderRound = providerRound
            record.lastReservedCostMicros = 0
            record.costStateRaw = AgentCostBudgetState.unavailable.rawValue
            record.updatedAt = Date()
            try modelContext.save()
            return costBudgetSnapshot(record)
        }
        let estimatedCostMicros = estimatedCostMicros!
        if record.lastReservedProviderRound == providerRound {
            return costBudgetSnapshot(record)
        }
        guard record.lastReservedProviderRound < Int.max,
              providerRound == record.lastReservedProviderRound + 1 else {
            throw AgentRequestPersistenceError.costBudgetMismatch
        }
        let total = record.reservedCostMicros.addingReportingOverflow(estimatedCostMicros)
        guard !total.overflow, total.partialValue <= record.maximumCostMicros else {
            throw AgentRequestPersistenceError.costBudgetExceeded
        }
        record.providerRaw = provider.rawValue
        record.model = model
        record.currency = currency
        record.pricingVersion = pricingVersion
        record.reservedCostMicros = total.partialValue
        record.lastReservedProviderRound = providerRound
        record.lastReservedCostMicros = estimatedCostMicros
        record.costStateRaw = AgentCostBudgetState.estimated.rawValue
        record.updatedAt = Date()
        try modelContext.save()
        return costBudgetSnapshot(record)
    }

    func markAgentRequestCostUnavailable(requestID: UUID, conversationID: UUID) throws {
        let record = try fetchCostBudgetRecord(requestID: requestID, conversationID: conversationID)
        record.costStateRaw = AgentCostBudgetState.unavailable.rawValue
        record.updatedAt = Date()
        try modelContext.save()
    }

    func addAgentRequestUsage(
        requestID: UUID,
        conversationID: UUID,
        usage: AgentTokenUsage
    ) throws {
        let record = try fetchAgentRequest(requestID: requestID, conversationID: conversationID)
        record.inputTokens = Self.add(record.inputTokens, usage.inputTokens)
        record.cachedInputTokens = Self.add(record.cachedInputTokens, usage.cachedInputTokens)
        record.outputTokens = Self.add(record.outputTokens, usage.outputTokens)
        record.reasoningTokens = Self.add(record.reasoningTokens, usage.reasoningTokens)
        record.updatedAt = Date()
        try modelContext.save()
    }

    func updateAgentRequestState(
        requestID: UUID,
        conversationID: UUID,
        state: AgentRequestState
    ) throws {
        let record = try fetchAgentRequest(requestID: requestID, conversationID: conversationID)
        record.stateRaw = state.rawValue
        record.updatedAt = Date()
        try modelContext.save()
    }

    func agentRequest(requestID: UUID, conversationID: UUID) throws -> AgentRequestSnapshot? {
        var descriptor = FetchDescriptor<AgentRequestRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        guard record.conversationID == conversationID else {
            throw AgentRequestPersistenceError.conversationMismatch
        }
        return try requestSnapshot(record)
    }

    func dailyMetrics(from startDate: Date, through endDate: Date) throws -> [AgentDailyMetric] {
        guard startDate <= endDate else { return [] }
        var cursor: Date?
        var metrics: [AgentDailyMetric] = []
        while true {
            let predicate: Predicate<DailyMetrics>
            if let cursor {
                let cursorDate = cursor
                predicate = #Predicate<DailyMetrics> { metric in
                    metric.date >= startDate && metric.date <= endDate && metric.date > cursorDate
                }
            } else {
                predicate = #Predicate<DailyMetrics> { metric in
                    metric.date >= startDate && metric.date <= endDate
                }
            }
            var descriptor = FetchDescriptor<DailyMetrics>(
                predicate: predicate,
                sortBy: [SortDescriptor(\DailyMetrics.date)]
            )
            descriptor.fetchLimit = Self.dailyMetricFetchBatchSize
            let batch = try modelContext.fetch(descriptor)
            guard let last = batch.last else { break }
            metrics.append(contentsOf: batch.map {
                DailyMetricsReadModelMapper.make($0)
            })
            cursor = last.date
        }
        return metrics
    }

    func schedule(on date: Date) throws -> [AgentScheduleItem] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let trainingPlanPrefix = ConfirmedTrainingPlanEntry.notesPrefix
        let eventPredicate = #Predicate<ScheduleEvent> { event in
            (event.date >= start && event.date < end)
                || event.notes?.contains(trainingPlanPrefix) == true
        }
        let eventSortBy = [
            SortDescriptor(\ScheduleEvent.date),
            SortDescriptor(\ScheduleEvent.startTime),
            SortDescriptor(\ScheduleEvent.createdAt),
            SortDescriptor(\ScheduleEvent.title),
            SortDescriptor(\ScheduleEvent.notes),
        ]
        var scheduleItems: [AgentScheduleItem] = []
        var eventOffset = 0
        while true {
            var descriptor = FetchDescriptor<ScheduleEvent>(predicate: eventPredicate, sortBy: eventSortBy)
            descriptor.fetchLimit = Self.scheduleEventFetchBatchSize
            descriptor.fetchOffset = eventOffset
            let events = try modelContext.fetch(descriptor)
            guard !events.isEmpty else { break }
            eventOffset += events.count

            for event in events {
                if let trainingPlan = ConfirmedTrainingPlanEntry.decode(notes: event.notes) {
                    guard trainingPlan.state != .terminal else { continue }
                    scheduleItems.append(contentsOf: trainingPlan.draft.sessions.compactMap { session in
                        guard calendar.isDate(session.date, inSameDayAs: date) else { return nil }
                        let planName = String(trainingPlan.draft.name.prefix(80))
                        let title = session.activity.map {
                            "\(planName) · \($0.displayName)"
                        } ?? "\(planName) · 休息日"
                        let reason = String(session.reason.prefix(240))
                        let notes: String
                        if session.activity == nil {
                            notes = reason
                        } else {
                            var details: [String] = []
                            if let goal = session.goal { details.append("目标：\(goal.displayName)") }
                            if let location = session.location { details.append("地点：\(location.displayName)") }
                            if let intensity = session.recommendedIntensity {
                                details.append("建议强度：\(intensity.displayName)")
                            }
                            details.append("理由：\(reason)")
                            notes = String(details.joined(separator: "；").prefix(600))
                        }
                        return AgentScheduleItem(
                            title: title,
                            startTime: session.date,
                            endTime: nil,
                            notes: notes
                        )
                    })
                    continue
                }

                guard event.date >= start, event.date < end else { continue }
                scheduleItems.append(
                    AgentScheduleItem(
                        title: event.title,
                        startTime: event.startTime,
                        endTime: event.endTime,
                        notes: ConfirmedWorkoutPlanEntry.decode(notes: event.notes) == nil
                            ? event.notes
                            : nil
                    )
                )
            }
        }
        return scheduleItems.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.title < $1.title
        }
    }

    func recentMeals(from startDate: Date, through endDate: Date, limit: Int) throws -> [AgentRecentMeal] {
        guard startDate <= endDate else { return [] }
        let cappedLimit = min(max(limit, 1), AgentRecentMealsLimits.maximumQueryMealCount)
        let predicate = #Predicate<MealRecord> { meal in
            meal.date >= startDate && meal.date <= endDate
        }
        var descriptor = FetchDescriptor<MealRecord>(predicate: predicate)
        descriptor.sortBy = [
            SortDescriptor(\MealRecord.date, order: .reverse),
            SortDescriptor(\MealRecord.createdAt, order: .reverse),
            SortDescriptor(\MealRecord.id, order: .reverse),
        ]
        descriptor.fetchLimit = cappedLimit
        return try modelContext.fetch(descriptor)
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            .prefix(cappedLimit)
            .map { meal in
                let estimate: AgentMealEnergyEstimate?
                let low = meal.energyLowKcal
                let likely = meal.energyLikelyKcal
                let high = meal.energyHighKcal
                if low.isFinite, likely.isFinite, high.isFinite,
                   low >= 0, likely >= low, high >= likely, high > 0 {
                    estimate = AgentMealEnergyEstimate(lowKcal: low, likelyKcal: likely, highKcal: high)
                } else {
                    estimate = nil
                }

                let dishes = meal.dishes
                    .sorted {
                        if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                        return $0.dishName.localizedStandardCompare($1.dishName) == .orderedAscending
                    }
                    .prefix(AgentRecentMealsLimits.maximumDishesPerMeal)
                    .compactMap { dish -> AgentMealDishSummary? in
                        let name = dish.dishName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, dish.estimatedCaloriesKcal >= 0 else { return nil }
                        return AgentMealDishSummary(
                            name: String(name.prefix(AgentRecentMealsLimits.maximumDishNameLength)),
                            likelyKcal: Self.availableLikelyKcal(for: dish)
                        )
                    }

                return AgentRecentMeal(
                    occurredAt: meal.date,
                    mealType: String(meal.mealType.prefix(AgentRecentMealsLimits.maximumMealTypeLength)),
                    energyEstimate: estimate,
                    dishes: dishes
                )
            }
    }

    private static func availableLikelyKcal(for dish: DishEntry) -> Int? {
        let likelyKcal = dish.estimatedCaloriesKcal
        guard likelyKcal >= 0 else { return nil }
        guard likelyKcal == 0 else { return likelyKcal }
        guard let evidenceData = dish.evidenceData,
              let evidence = try? JSONDecoder().decode([EvidenceSnapshot].self, from: evidenceData),
              !evidence.isEmpty,
              evidence.allSatisfy({
                  $0.grade != .legacyPointEstimate && $0.grade != .unresolved
              }) else {
            return nil
        }
        return likelyKcal
    }

    func recentWorkouts(from startDate: Date, through endDate: Date, limit: Int) throws -> [AgentRecentWorkout] {
        guard startDate <= endDate else { return [] }
        let cappedLimit = min(max(limit, 1), AgentRecentWorkoutsLimits.maximumQueryWorkoutCount)
        let sortDescriptors = [
            SortDescriptor(\WorkoutRecord.date, order: .reverse),
            SortDescriptor(\WorkoutRecord.createdAt, order: .reverse),
            SortDescriptor(\WorkoutRecord.id, order: .reverse),
        ]
        var allowedWorkouts: [WorkoutRecord] = []
        var cursorDate: Date?
        var cursorCreatedAt: Date?
        var cursorID: UUID?
        while allowedWorkouts.count < cappedLimit {
            let predicate: Predicate<WorkoutRecord>
            if let cursorDate, let cursorCreatedAt, let cursorID {
                let lastDate = cursorDate
                let lastCreatedAt = cursorCreatedAt
                let lastID = cursorID
                predicate = #Predicate<WorkoutRecord> { workout in
                    workout.date >= startDate && workout.date <= endDate && workout.durationMinutes > 0
                        && (workout.date < lastDate
                            || (workout.date == lastDate
                                && (workout.createdAt < lastCreatedAt
                                    || (workout.createdAt == lastCreatedAt && workout.id < lastID))))
                }
            } else {
                predicate = #Predicate<WorkoutRecord> { workout in
                    workout.date >= startDate && workout.date <= endDate && workout.durationMinutes > 0
                }
            }
            var descriptor = FetchDescriptor<WorkoutRecord>(predicate: predicate, sortBy: sortDescriptors)
            descriptor.fetchLimit = Self.recentWorkoutFetchBatchSize
            let page = try modelContext.fetch(descriptor)
            guard !page.isEmpty else { break }
            let readStates = try healthKitWorkoutReadStates(for: page)
            allowedWorkouts.append(contentsOf: page.filter { workout in
                guard workout.healthKitUUID != nil else { return true }
                return readStates[Self.dayKey(for: workout.date)] == .available
            })
            guard page.count == Self.recentWorkoutFetchBatchSize, let last = page.last else { break }
            cursorDate = last.date
            cursorCreatedAt = last.createdAt
            cursorID = last.id
        }
        return allowedWorkouts
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            .prefix(cappedLimit)
            .map { workout in
                AgentRecentWorkout(
                    occurredAt: workout.date,
                    workoutType: String(workout.type.prefix(AgentRecentWorkoutsLimits.maximumWorkoutTypeLength)),
                    durationMinutes: max(workout.durationMinutes, 0),
                    intensity: String(workout.intensity.prefix(AgentRecentWorkoutsLimits.maximumIntensityLength)),
                    estimatedCaloriesKcal: workout.estimatedCaloriesBurned > 0
                        ? workout.estimatedCaloriesBurned
                        : nil
                )
            }
    }

    private func healthKitWorkoutReadStates(for workouts: [WorkoutRecord]) throws -> [String: HealthReadState] {
        let dayKeys = Array(Set(workouts.compactMap { workout in
            workout.healthKitUUID == nil ? nil : Self.dayKey(for: workout.date)
        })).sorted()
        guard !dayKeys.isEmpty else { return [:] }
        var states: [String: HealthReadState] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var offset = 0
        while offset < dayKeys.count {
            let batchEnd = min(offset + Self.recentWorkoutFetchBatchSize, dayKeys.count)
            let keys = Array(dayKeys[offset..<batchEnd])
            let predicate = #Predicate<DailyHealthSnapshotRecord> { keys.contains($0.dayKey) }
            for record in try modelContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>(predicate: predicate)) {
                guard let snapshot = try? decoder.decode(DailyHealthSnapshot.self, from: record.payloadData),
                      let state = snapshot.healthReadStates?[HealthMetricID.workout.rawValue] else {
                    continue
                }
                states[record.dayKey] = state
            }
            offset = batchEnd
        }
        return states
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func userPreferences(limit: Int) throws -> [AgentUserPreference] {
        let cappedLimit = min(max(limit, 1), AgentUserPreferencesLimits.maximumQueryPreferenceCount)
        let userReportedSource = UserPreferenceSource.userReported.rawValue
        let sortBy = [
            SortDescriptor(\UserPreferenceRecord.createdAt, order: .reverse),
            SortDescriptor(\UserPreferenceRecord.sourceActionKey),
        ]
        var cursor: UserPreferenceCursor?
        var candidates: [UserPreferenceCandidate] = []
        var reachedCutoff = false
        while !reachedCutoff {
            let predicate: Predicate<UserPreferenceRecord>
            if let cursor {
                let cursorCreatedAt = cursor.createdAt
                let cursorSourceActionKey = cursor.sourceActionKey
                predicate = #Predicate<UserPreferenceRecord> {
                    $0.sourceRaw == userReportedSource
                        && ($0.createdAt < cursorCreatedAt
                            || ($0.createdAt == cursorCreatedAt
                                && $0.sourceActionKey > cursorSourceActionKey))
                }
            } else {
                predicate = #Predicate<UserPreferenceRecord> { $0.sourceRaw == userReportedSource }
            }
            var descriptor = FetchDescriptor<UserPreferenceRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.userPreferenceFetchBatchSize
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for record in batch {
                cursor = UserPreferenceCursor(
                    createdAt: record.createdAt,
                    sourceActionKey: record.sourceActionKey
                )
                if candidates.count == cappedLimit,
                   let cutoffDate = candidates.last?.record.createdAt,
                   record.createdAt < cutoffDate {
                    reachedCutoff = true
                    break
                }
                guard let category = UserPreferenceCategory(rawValue: record.categoryRaw) else {
                    continue
                }
                let statement = record.statement.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !statement.isEmpty, statement.count <= 500 else { continue }
                candidates.append(UserPreferenceCandidate(
                    record: record,
                    category: category,
                    statement: String(statement.prefix(AgentUserPreferencesLimits.maximumStatementLength))
                ))
                candidates.sort {
                    if $0.record.createdAt != $1.record.createdAt {
                        return $0.record.createdAt > $1.record.createdAt
                    }
                    return $0.record.id.uuidString < $1.record.id.uuidString
                }
                if candidates.count > cappedLimit { candidates.removeLast() }
            }
        }
        return candidates.map { AgentUserPreference(category: $0.category, statement: $0.statement) }
    }

    func ensureConversation(id: UUID) throws {
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let existingConversation = try modelContext.fetch(descriptor).first
        if existingConversation == nil {
            modelContext.insert(ConversationRecord(id: id))
        }

        let versionPredicate = #Predicate<ConversationToolSchemaVersionRecord> {
            $0.conversationID == id
        }
        var versionDescriptor = FetchDescriptor<ConversationToolSchemaVersionRecord>(predicate: versionPredicate)
        versionDescriptor.fetchLimit = 1
        if try modelContext.fetch(versionDescriptor).first == nil {
            let hasHistory: Bool
            if existingConversation != nil {
                hasHistory = try hasPersistedConversationHistory(id: id)
            } else {
                hasHistory = false
            }
            let schemaVersion = hasHistory ? ToolSchemaVersion.legacy : ToolSchemaVersion.current
            modelContext.insert(ConversationToolSchemaVersionRecord(
                conversationID: id,
                toolSchemaVersion: schemaVersion
            ))
        }
        try modelContext.save()
    }

    func toolSchemaVersion(conversationID: UUID) throws -> Int {
        try ensureConversation(id: conversationID)
        let predicate = #Predicate<ConversationToolSchemaVersionRecord> {
            $0.conversationID == conversationID
        }
        var descriptor = FetchDescriptor<ConversationToolSchemaVersionRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            throw AgentRequestPersistenceError.invalidState("conversation tool schema metadata missing")
        }
        return record.toolSchemaVersion
    }

    func appendMessage(
        conversationID: UUID,
        role: String,
        contentData: Data,
        toolSummaryData: Data?,
        requestID: UUID?
    ) throws {
        try ensureConversation(id: conversationID)
        var latestMessageDescriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\MessageRecord.ordinal, order: .reverse)]
        )
        latestMessageDescriptor.fetchLimit = 1
        let ordinal = (try modelContext.fetch(latestMessageDescriptor).first?.ordinal ?? -1) + 1
        modelContext.insert(
            MessageRecord(
                conversationID: conversationID,
                roleRaw: role,
                contentData: contentData,
                toolSummaryData: toolSummaryData,
                ordinal: ordinal,
                requestID: requestID
            )
        )
        var conversationDescriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        conversationDescriptor.fetchLimit = 1
        if let conversation = try modelContext.fetch(conversationDescriptor).first {
            conversation.updatedAt = Date()
            let versionPredicate = #Predicate<ConversationToolSchemaVersionRecord> {
                $0.conversationID == conversationID
            }
            var versionDescriptor = FetchDescriptor<ConversationToolSchemaVersionRecord>(predicate: versionPredicate)
            versionDescriptor.fetchLimit = 1
            if let version = try modelContext.fetch(versionDescriptor).first {
                version.toolSchemaVersion = ToolSchemaVersion.current
                version.updatedAt = Date()
            } else {
                modelContext.insert(ConversationToolSchemaVersionRecord(
                    conversationID: conversationID,
                    toolSchemaVersion: ToolSchemaVersion.current
                ))
            }
        }
        try modelContext.save()
    }

    private func hasPersistedConversationHistory(id: UUID) throws -> Bool {
        let messagePredicate = #Predicate<MessageRecord> { $0.conversationID == id }
        var messageDescriptor = FetchDescriptor<MessageRecord>(predicate: messagePredicate)
        messageDescriptor.fetchLimit = 1
        if try modelContext.fetch(messageDescriptor).first != nil { return true }

        let requestPredicate = #Predicate<AgentRequestRecord> { $0.conversationID == id }
        var requestDescriptor = FetchDescriptor<AgentRequestRecord>(predicate: requestPredicate)
        requestDescriptor.fetchLimit = 1
        return try modelContext.fetch(requestDescriptor).first != nil
    }

    func messageData(conversationID: UUID) throws -> [Data] {
        try fetchMessageData(conversationID: conversationID, excludingRequestID: nil)
    }

    func resumeHistory(conversationID: UUID, requestID: UUID) throws -> [Data] {
        try fetchMessageData(conversationID: conversationID, excludingRequestID: requestID)
    }

    private func fetchMessageData(conversationID: UUID, excludingRequestID: UUID?) throws -> [Data] {
        let sortBy = [
            SortDescriptor(\MessageRecord.ordinal),
            SortDescriptor(\MessageRecord.id),
        ]
        var cursor: MessageCursor?
        var contentData: [Data] = []
        while true {
            let predicate: Predicate<MessageRecord>
            if let cursor {
                let cursorOrdinal = cursor.ordinal
                let cursorID = cursor.id
                if let excludingRequestID {
                    predicate = #Predicate<MessageRecord> { message in
                        message.conversationID == conversationID
                            && (message.requestID == nil
                                || message.requestID != excludingRequestID
                                || message.roleRaw == "user")
                            && (message.ordinal > cursorOrdinal
                                || (message.ordinal == cursorOrdinal && message.id > cursorID))
                    }
                } else {
                    predicate = #Predicate<MessageRecord> { message in
                        message.conversationID == conversationID
                            && (message.ordinal > cursorOrdinal
                                || (message.ordinal == cursorOrdinal && message.id > cursorID))
                    }
                }
            } else if let excludingRequestID {
                predicate = #Predicate<MessageRecord> { message in
                    message.conversationID == conversationID
                        && (message.requestID == nil
                            || message.requestID != excludingRequestID
                            || message.roleRaw == "user")
                }
            } else {
                predicate = #Predicate<MessageRecord> { message in
                    message.conversationID == conversationID
                }
            }
            var descriptor = FetchDescriptor<MessageRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.messageFetchBatchSize
            let batch = try modelContext.fetch(descriptor)
            guard let last = batch.last else { break }
            contentData.append(contentsOf: batch.map(\.contentData))
            cursor = MessageCursor(ordinal: last.ordinal, id: last.id)
        }
        return contentData
    }

    func containsRequestID(_ requestID: UUID, conversationID: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.conversationID == conversationID && $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first != nil
    }

    func containsCompletedResponse(requestID: UUID, conversationID: UUID) throws -> Bool {
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.conversationID == conversationID
                    && $0.requestID == requestID
                    && $0.roleRaw == "assistant"
                    && $0.toolSummaryData == nil
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first != nil
    }

    func reset(conversationID: UUID) throws {
        let messageSortBy = [
            SortDescriptor(\MessageRecord.ordinal),
            SortDescriptor(\MessageRecord.id),
        ]
        var messageCursor: MessageCursor?
        while true {
            let messagePredicate: Predicate<MessageRecord>
            if let messageCursor {
                let cursorOrdinal = messageCursor.ordinal
                let cursorID = messageCursor.id
                messagePredicate = #Predicate<MessageRecord> { message in
                    message.conversationID == conversationID
                        && (message.ordinal > cursorOrdinal
                            || (message.ordinal == cursorOrdinal && message.id > cursorID))
                }
            } else {
                messagePredicate = #Predicate<MessageRecord> { $0.conversationID == conversationID }
            }
            var messageDescriptor = FetchDescriptor<MessageRecord>(
                predicate: messagePredicate,
                sortBy: messageSortBy
            )
            messageDescriptor.fetchLimit = Self.conversationResetBatchSize
            let messages = try modelContext.fetch(messageDescriptor)
            guard let lastMessage = messages.last else { break }
            for message in messages { modelContext.delete(message) }
            messageCursor = MessageCursor(ordinal: lastMessage.ordinal, id: lastMessage.id)
        }

        var requestCursor: UUID?
        let requestSortBy = [SortDescriptor(\AgentRequestRecord.requestID)]
        while true {
            let requestPredicate: Predicate<AgentRequestRecord>
            if let requestCursor {
                let cursorRequestID = requestCursor
                requestPredicate = #Predicate<AgentRequestRecord> { request in
                    request.conversationID == conversationID && request.requestID > cursorRequestID
                }
            } else {
                requestPredicate = #Predicate<AgentRequestRecord> { $0.conversationID == conversationID }
            }
            var requestDescriptor = FetchDescriptor<AgentRequestRecord>(
                predicate: requestPredicate,
                sortBy: requestSortBy
            )
            requestDescriptor.fetchLimit = Self.conversationResetBatchSize
            let requests = try modelContext.fetch(requestDescriptor)
            guard let lastRequest = requests.last else { break }
            for request in requests { modelContext.delete(request) }
            requestCursor = lastRequest.requestID
        }

        var costBudgetCursor: UUID?
        let costBudgetSortBy = [SortDescriptor(\AgentRequestCostBudgetRecord.requestID)]
        while true {
            let costBudgetPredicate: Predicate<AgentRequestCostBudgetRecord>
            if let costBudgetCursor {
                let cursorRequestID = costBudgetCursor
                costBudgetPredicate = #Predicate<AgentRequestCostBudgetRecord> { budget in
                    budget.conversationID == conversationID && budget.requestID > cursorRequestID
                }
            } else {
                costBudgetPredicate = #Predicate<AgentRequestCostBudgetRecord> {
                    $0.conversationID == conversationID
                }
            }
            var costBudgetDescriptor = FetchDescriptor<AgentRequestCostBudgetRecord>(
                predicate: costBudgetPredicate,
                sortBy: costBudgetSortBy
            )
            costBudgetDescriptor.fetchLimit = Self.conversationResetBatchSize
            let budgets = try modelContext.fetch(costBudgetDescriptor)
            guard let lastBudget = budgets.last else { break }
            for budget in budgets { modelContext.delete(budget) }
            costBudgetCursor = lastBudget.requestID
        }

        var conversationDescriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        conversationDescriptor.fetchLimit = 1
        if let conversation = try modelContext.fetch(conversationDescriptor).first {
            conversation.updatedAt = Date()
            let versionPredicate = #Predicate<ConversationToolSchemaVersionRecord> {
                $0.conversationID == conversationID
            }
            var versionDescriptor = FetchDescriptor<ConversationToolSchemaVersionRecord>(predicate: versionPredicate)
            versionDescriptor.fetchLimit = 1
            if let version = try modelContext.fetch(versionDescriptor).first {
                version.toolSchemaVersion = ToolSchemaVersion.current
                version.updatedAt = Date()
            } else {
                modelContext.insert(ConversationToolSchemaVersionRecord(
                    conversationID: conversationID,
                    toolSchemaVersion: ToolSchemaVersion.current
                ))
            }
        }
        try modelContext.save()
    }

    private func fetchAgentRequest(requestID: UUID, conversationID: UUID) throws -> AgentRequestRecord {
        var descriptor = FetchDescriptor<AgentRequestRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            throw AgentRequestPersistenceError.requestNotFound
        }
        guard record.conversationID == conversationID else {
            throw AgentRequestPersistenceError.conversationMismatch
        }
        return record
    }

    private func requestSnapshot(_ record: AgentRequestRecord) throws -> AgentRequestSnapshot {
        let state = try requestState(record)
        let costBudgetRecord = try findCostBudgetRecord(
            requestID: record.requestID,
            conversationID: record.conversationID
        )
        let costBudget = costBudgetRecord.map(costBudgetSnapshot)
            ?? AgentRequestCostBudget(
                maximumCostMicros: AgentBudget.defaultMaximumCostMicros,
                reservedCostMicros: 0,
                provider: nil,
                model: nil,
                currency: nil,
                pricingVersion: nil,
                lastReservedProviderRound: 0,
                lastReservedCostMicros: 0,
                state: .unavailable
            )
        return AgentRequestSnapshot(
            requestID: record.requestID,
            conversationID: record.conversationID,
            startedAt: record.startedAt,
            budget: AgentBudget(
                maximumProviderRounds: record.maximumProviderRounds,
                maximumToolCalls: record.maximumToolCalls,
                maximumCostMicros: costBudget.maximumCostMicros,
                deadline: record.absoluteDeadline
            ),
            consumption: AgentBudgetConsumption(
                providerRoundsUsed: record.providerRoundsUsed,
                toolCallsUsed: record.toolCallsUsed,
                inputTokens: record.inputTokens,
                cachedInputTokens: record.cachedInputTokens,
                outputTokens: record.outputTokens,
                reasoningTokens: record.reasoningTokens
            ),
            costBudget: costBudget,
            resumeCount: record.resumeCount,
            containsTransientImage: record.containsTransientImage,
            state: state
        )
    }

    private func ensureCostBudgetRecord(
        for request: AgentRequestRecord,
        fallbackMaximumCostMicros: Int64
    ) throws {
        if let existing = try findCostBudgetRecord(
            requestID: request.requestID,
            conversationID: request.conversationID
        ) {
            guard AgentCostBudgetState(rawValue: existing.costStateRaw) == .estimated else { return }
            let usages = try providerUsageRecords(for: request.requestID)
            let hasUnpricedOrMismatchedUsage = usages.count >= 64
                || usages.contains { usage in
                    usage.estimatedCostMicros < 0
                        || usage.provider != existing.providerRaw
                        || usage.model != existing.model
                        || usage.currency != existing.currency
                        || usage.rateVersion != existing.pricingVersion
                }
            if hasUnpricedOrMismatchedUsage {
                existing.costStateRaw = AgentCostBudgetState.unavailable.rawValue
                existing.updatedAt = Date()
                try modelContext.save()
            }
            return
        }
        let hasPriorUsage = request.providerRoundsUsed > 0
            || request.inputTokens > 0
            || request.cachedInputTokens > 0
            || request.outputTokens > 0
            || request.reasoningTokens > 0
        let record = AgentRequestCostBudgetRecord(
            requestID: request.requestID,
            conversationID: request.conversationID,
            maximumCostMicros: fallbackMaximumCostMicros,
            costStateRaw: hasPriorUsage
                ? AgentCostBudgetState.unavailable.rawValue
                : AgentCostBudgetState.unresolved.rawValue
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    private func providerUsageRecords(for requestID: UUID) throws -> [ProviderUsageRecord] {
        let requestToken = requestID.uuidString.lowercased()
        let predicate = #Predicate<ProviderUsageRecord> { $0.usageKey.contains(requestToken) }
        var descriptor = FetchDescriptor<ProviderUsageRecord>(predicate: predicate)
        descriptor.fetchLimit = 64
        return try modelContext.fetch(descriptor)
    }

    private func fetchCostBudgetRecord(requestID: UUID, conversationID: UUID) throws -> AgentRequestCostBudgetRecord {
        guard let record = try findCostBudgetRecord(requestID: requestID, conversationID: conversationID) else {
            throw AgentRequestPersistenceError.costBudgetUnavailable
        }
        return record
    }

    private func findCostBudgetRecord(
        requestID: UUID,
        conversationID: UUID
    ) throws -> AgentRequestCostBudgetRecord? {
        var descriptor = FetchDescriptor<AgentRequestCostBudgetRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        guard record.conversationID == conversationID else {
            throw AgentRequestPersistenceError.conversationMismatch
        }
        return record
    }

    private func costBudgetSnapshot(_ record: AgentRequestCostBudgetRecord) -> AgentRequestCostBudget {
        AgentRequestCostBudget(
            maximumCostMicros: record.maximumCostMicros,
            reservedCostMicros: record.reservedCostMicros,
            provider: ProviderID(rawValue: record.providerRaw),
            model: record.model == "unresolved" ? nil : record.model,
            currency: record.currency == "unresolved" ? nil : record.currency,
            pricingVersion: record.pricingVersion == "unavailable" ? nil : record.pricingVersion,
            lastReservedProviderRound: record.lastReservedProviderRound,
            lastReservedCostMicros: record.lastReservedCostMicros,
            state: AgentCostBudgetState(rawValue: record.costStateRaw) ?? .unavailable
        )
    }

    private func requestState(_ record: AgentRequestRecord) throws -> AgentRequestState {
        guard let state = AgentRequestState(rawValue: record.stateRaw) else {
            throw AgentRequestPersistenceError.invalidState(record.stateRaw)
        }
        return state
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
}
