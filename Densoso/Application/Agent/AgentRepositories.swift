import Foundation

struct AgentDailyMetric: Codable, Equatable, Sendable {
    let date: Date
    let deficitKcal: Int
    let intakeKcal: Int
    let expenditureKcal: Int
    let mealCount: Int
    let workoutCount: Int
}

struct AgentScheduleItem: Codable, Equatable, Sendable {
    let title: String
    let startTime: Date
    let endTime: Date?
    let notes: String?
}

protocol AgentReadRepository: Sendable {
    func dailyMetrics(from startDate: Date, through endDate: Date) async throws -> [AgentDailyMetric]
    func schedule(on date: Date) async throws -> [AgentScheduleItem]
}

protocol ConversationRepository: Sendable {
    func ensureConversation(id: UUID) async throws
    func appendMessage(
        conversationID: UUID,
        role: String,
        contentData: Data,
        requestID: UUID?
    ) async throws
    func messageData(conversationID: UUID) async throws -> [Data]
    func reset(conversationID: UUID) async throws
}
