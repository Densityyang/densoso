import Foundation
import SwiftData

@ModelActor
actor SwiftDataAgentRepository: AgentReadRepository, ConversationRepository {
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
        return try modelContext.fetch(FetchDescriptor<ScheduleEvent>())
            .filter { $0.date >= start && $0.date < end }
            .sorted { $0.startTime < $1.startTime }
            .map {
                AgentScheduleItem(
                    title: $0.title,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    notes: $0.notes
                )
            }
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

    func reset(conversationID: UUID) throws {
        let messages = try modelContext.fetch(FetchDescriptor<MessageRecord>())
            .filter { $0.conversationID == conversationID }
        for message in messages { modelContext.delete(message) }
        if let conversation = try modelContext.fetch(FetchDescriptor<ConversationRecord>())
            .first(where: { $0.id == conversationID }) {
            conversation.updatedAt = Date()
        }
        try modelContext.save()
    }
}
