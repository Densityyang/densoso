import Foundation
import DensosoDomain

typealias AgentDailyMetric = DailyMetricsReadResult

struct AgentScheduleItem: Codable, Equatable, Sendable {
    let title: String
    let startTime: Date
    let endTime: Date?
    let notes: String?
}

struct AgentMealEnergyEstimate: Equatable, Sendable {
    let lowKcal: Double
    let likelyKcal: Double
    let highKcal: Double
}

struct AgentMealDishSummary: Equatable, Sendable {
    let name: String
    let likelyKcal: Int
}

/// A narrow, presentation-safe meal summary. It intentionally excludes storage IDs,
/// raw ingredient/evidence JSON, notes and persistence metadata.
struct AgentRecentMeal: Equatable, Sendable {
    let occurredAt: Date
    let mealType: String
    let energyEstimate: AgentMealEnergyEstimate?
    let dishes: [AgentMealDishSummary]
}

struct AgentRecentWorkout: Equatable, Sendable {
    let occurredAt: Date
    let workoutType: String
    let durationMinutes: Int
    let intensity: String
    let estimatedCaloriesKcal: Int?
}

/// Minimal confirmed user-preference content returned to an explicit on-demand query.
/// It intentionally carries neither persistence identifiers nor source metadata.
struct AgentUserPreference: Equatable, Sendable {
    let category: UserPreferenceCategory
    let statement: String
}

enum AgentRecentMealsLimits {
    static let maximumDays = 30
    static let maximumMealCount = 20
    static let maximumQueryMealCount = maximumMealCount + 1
    static let maximumDishesPerMeal = 4
    static let maximumDishNameLength = 60
    static let maximumMealTypeLength = 40
    static let maximumOutputCharacters = 7_500
}

enum AgentRecentWorkoutsLimits {
    static let maximumDays = 30
    static let maximumWorkoutCount = 20
    static let maximumQueryWorkoutCount = maximumWorkoutCount + 1
    static let maximumWorkoutTypeLength = 60
    static let maximumIntensityLength = 40
    static let maximumOutputCharacters = 7_500
}

enum AgentUserPreferencesLimits {
    static let defaultPreferenceCount = 10
    static let maximumPreferenceCount = 20
    static let maximumQueryPreferenceCount = maximumPreferenceCount + 1
    static let maximumStatementLength = 500
    static let maximumOutputCharacters = 7_500
}

enum AgentRequestState: String, Codable, CaseIterable, Sendable {
    case running
    case interrupted
    case completed
    case failed
    case expired
}

struct AgentTokenUsage: Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int

    init(inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int, reasoningTokens: Int = 0) {
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningTokens = max(reasoningTokens, 0)
    }
}

struct AgentBudgetConsumption: Equatable, Sendable {
    let providerRoundsUsed: Int
    let toolCallsUsed: Int
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int

    static let zero = AgentBudgetConsumption()

    init(
        providerRoundsUsed: Int = 0,
        toolCallsUsed: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0
    ) {
        self.providerRoundsUsed = max(providerRoundsUsed, 0)
        self.toolCallsUsed = max(toolCallsUsed, 0)
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = max(cachedInputTokens, 0)
        self.outputTokens = max(outputTokens, 0)
        self.reasoningTokens = max(reasoningTokens, 0)
    }

    func addingProviderRound() -> AgentBudgetConsumption {
        AgentBudgetConsumption(
            providerRoundsUsed: Self.increment(providerRoundsUsed),
            toolCallsUsed: toolCallsUsed,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens
        )
    }

    func addingToolCall() -> AgentBudgetConsumption {
        AgentBudgetConsumption(
            providerRoundsUsed: providerRoundsUsed,
            toolCallsUsed: Self.increment(toolCallsUsed),
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens
        )
    }

    func adding(_ usage: AgentTokenUsage) -> AgentBudgetConsumption {
        AgentBudgetConsumption(
            providerRoundsUsed: providerRoundsUsed,
            toolCallsUsed: toolCallsUsed,
            inputTokens: Self.add(inputTokens, usage.inputTokens),
            cachedInputTokens: Self.add(cachedInputTokens, usage.cachedInputTokens),
            outputTokens: Self.add(outputTokens, usage.outputTokens),
            reasoningTokens: Self.add(reasoningTokens, usage.reasoningTokens)
        )
    }

    private static func increment(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
}

struct AgentRequestSnapshot: Equatable, Sendable {
    let requestID: UUID
    let conversationID: UUID
    let startedAt: Date
    let budget: AgentBudget
    let consumption: AgentBudgetConsumption
    let resumeCount: Int
    let containsTransientImage: Bool
    let state: AgentRequestState
}

enum AgentRequestPersistenceError: Error, Equatable {
    case requestNotFound
    case conversationMismatch
    case requestMediaMismatch
    case invalidState(String)
}

protocol AgentReadRepository: Sendable {
    func dailyMetrics(from startDate: Date, through endDate: Date) async throws -> [AgentDailyMetric]
    func schedule(on date: Date) async throws -> [AgentScheduleItem]
    func recentMeals(from startDate: Date, through endDate: Date, limit: Int) async throws -> [AgentRecentMeal]
    func recentWorkouts(from startDate: Date, through endDate: Date, limit: Int) async throws -> [AgentRecentWorkout]
    func userPreferences(limit: Int) async throws -> [AgentUserPreference]
}

protocol ConversationRepository: Sendable {
    func beginAgentRequest(
        requestID: UUID,
        conversationID: UUID,
        initialBudget: AgentBudget,
        startedAt: Date,
        containsTransientImage: Bool
    ) async throws -> AgentRequestSnapshot
    func updateAgentRequestConsumption(
        requestID: UUID,
        conversationID: UUID,
        consumption: AgentBudgetConsumption
    ) async throws
    func addAgentRequestUsage(
        requestID: UUID,
        conversationID: UUID,
        usage: AgentTokenUsage
    ) async throws
    func updateAgentRequestState(
        requestID: UUID,
        conversationID: UUID,
        state: AgentRequestState
    ) async throws
    func agentRequest(requestID: UUID, conversationID: UUID) async throws -> AgentRequestSnapshot?
    func ensureConversation(id: UUID) async throws
    func appendMessage(
        conversationID: UUID,
        role: String,
        contentData: Data,
        toolSummaryData: Data?,
        requestID: UUID?
    ) async throws
    func messageData(conversationID: UUID) async throws -> [Data]
    func resumeHistory(conversationID: UUID, requestID: UUID) async throws -> [Data]
    func containsRequestID(_ requestID: UUID, conversationID: UUID) async throws -> Bool
    func containsCompletedResponse(requestID: UUID, conversationID: UUID) async throws -> Bool
    func toolSchemaVersion(conversationID: UUID) async throws -> Int
    func reset(conversationID: UUID) async throws
}
