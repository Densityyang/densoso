import Foundation
import DensosoDomain
import SwiftData

@ModelActor
actor SwiftDataAgentRepository: AgentReadRepository, ConversationRepository {
    func beginAgentRequest(
        requestID: UUID,
        conversationID: UUID,
        initialBudget: AgentBudget,
        startedAt: Date,
        containsTransientImage: Bool
    ) throws -> AgentRequestSnapshot {
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
        let descriptor = FetchDescriptor<AgentRequestRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        guard record.conversationID == conversationID else {
            throw AgentRequestPersistenceError.conversationMismatch
        }
        return try requestSnapshot(record)
    }

    func dailyMetrics(from startDate: Date, through endDate: Date) throws -> [AgentDailyMetric] {
        try modelContext.fetch(FetchDescriptor<DailyMetrics>())
            .filter { $0.date >= startDate && $0.date <= endDate }
            .sorted { $0.date < $1.date }
            .map {
                AgentDailyMetric(
                    date: $0.date,
                    deficitKcal: $0.deficitKcal,
                    intakeKcal: $0.totalIntakeKcal,
                    expenditureKcal: $0.totalExpenditureKcal,
                    mealCount: $0.mealCount,
                    workoutCount: $0.workoutCount
                )
            }
    }

    func schedule(on date: Date) throws -> [AgentScheduleItem] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        var scheduleItems: [AgentScheduleItem] = []
        for event in try modelContext.fetch(FetchDescriptor<ScheduleEvent>()) {
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
                            likelyKcal: dish.estimatedCaloriesKcal
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

    func recentWorkouts(from startDate: Date, through endDate: Date, limit: Int) throws -> [AgentRecentWorkout] {
        guard startDate <= endDate else { return [] }
        let cappedLimit = min(max(limit, 1), AgentRecentWorkoutsLimits.maximumQueryWorkoutCount)
        let predicate = #Predicate<WorkoutRecord> { workout in
            workout.date >= startDate && workout.date <= endDate && workout.durationMinutes > 0
        }
        var descriptor = FetchDescriptor<WorkoutRecord>(predicate: predicate)
        descriptor.sortBy = [
            SortDescriptor(\WorkoutRecord.date, order: .reverse),
            SortDescriptor(\WorkoutRecord.createdAt, order: .reverse),
            SortDescriptor(\WorkoutRecord.id, order: .reverse),
        ]
        descriptor.fetchLimit = cappedLimit
        return try modelContext.fetch(descriptor)
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

    func userPreferences(limit: Int) throws -> [AgentUserPreference] {
        let cappedLimit = min(max(limit, 1), AgentUserPreferencesLimits.maximumQueryPreferenceCount)
        let candidates: [(
            record: UserPreferenceRecord,
            category: UserPreferenceCategory,
            statement: String
        )] = try modelContext.fetch(FetchDescriptor<UserPreferenceRecord>()).compactMap { record in
            guard record.sourceRaw == UserPreferenceSource.userReported.rawValue,
                  let category = UserPreferenceCategory(rawValue: record.categoryRaw) else {
                return nil
            }
            let statement = record.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty, statement.count <= 500 else { return nil }
            return (record, category, String(statement.prefix(AgentUserPreferencesLimits.maximumStatementLength)))
        }
        return candidates
            .sorted {
                if $0.record.createdAt != $1.record.createdAt {
                    return $0.record.createdAt > $1.record.createdAt
                }
                return $0.record.id.uuidString < $1.record.id.uuidString
            }
            .prefix(cappedLimit)
            .map { AgentUserPreference(category: $0.category, statement: $0.statement) }
    }

    func ensureConversation(id: UUID) throws {
        let exists = try modelContext.fetch(FetchDescriptor<ConversationRecord>()).contains { $0.id == id }
        guard !exists else { return }
        modelContext.insert(ConversationRecord(id: id))
        try modelContext.save()
    }

    func appendMessage(
        conversationID: UUID,
        role: String,
        contentData: Data,
        toolSummaryData: Data?,
        requestID: UUID?
    ) throws {
        try ensureConversation(id: conversationID)
        let existing = try modelContext.fetch(FetchDescriptor<MessageRecord>())
            .filter { $0.conversationID == conversationID }
        let ordinal = (existing.map(\.ordinal).max() ?? -1) + 1
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
        if let conversation = try modelContext.fetch(FetchDescriptor<ConversationRecord>())
            .first(where: { $0.id == conversationID }) {
            conversation.updatedAt = Date()
        }
        try modelContext.save()
    }

    func messageData(conversationID: UUID) throws -> [Data] {
        try modelContext.fetch(FetchDescriptor<MessageRecord>())
            .filter { $0.conversationID == conversationID }
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.contentData)
    }

    func resumeHistory(conversationID: UUID, requestID: UUID) throws -> [Data] {
        try modelContext.fetch(FetchDescriptor<MessageRecord>())
            .filter {
                $0.conversationID == conversationID
                    && ($0.requestID != requestID || $0.roleRaw == "user")
            }
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.contentData)
    }

    func containsRequestID(_ requestID: UUID, conversationID: UUID) throws -> Bool {
        try modelContext.fetch(FetchDescriptor<MessageRecord>())
            .contains { $0.conversationID == conversationID && $0.requestID == requestID }
    }

    func containsCompletedResponse(requestID: UUID, conversationID: UUID) throws -> Bool {
        try modelContext.fetch(FetchDescriptor<MessageRecord>())
            .contains {
                $0.conversationID == conversationID
                    && $0.requestID == requestID
                    && $0.roleRaw == "assistant"
                    && $0.toolSummaryData == nil
            }
    }

    func reset(conversationID: UUID) throws {
        let messages = try modelContext.fetch(FetchDescriptor<MessageRecord>())
            .filter { $0.conversationID == conversationID }
        for message in messages { modelContext.delete(message) }
        let requests = try modelContext.fetch(FetchDescriptor<AgentRequestRecord>())
            .filter { $0.conversationID == conversationID }
        for request in requests { modelContext.delete(request) }
        if let conversation = try modelContext.fetch(FetchDescriptor<ConversationRecord>())
            .first(where: { $0.id == conversationID }) {
            conversation.updatedAt = Date()
        }
        try modelContext.save()
    }

    private func fetchAgentRequest(requestID: UUID, conversationID: UUID) throws -> AgentRequestRecord {
        let descriptor = FetchDescriptor<AgentRequestRecord>(
            predicate: #Predicate { $0.requestID == requestID }
        )
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
        return AgentRequestSnapshot(
            requestID: record.requestID,
            conversationID: record.conversationID,
            startedAt: record.startedAt,
            budget: AgentBudget(
                maximumProviderRounds: record.maximumProviderRounds,
                maximumToolCalls: record.maximumToolCalls,
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
            resumeCount: record.resumeCount,
            containsTransientImage: record.containsTransientImage,
            state: state
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
