import DensosoDomain
import Foundation

@MainActor
final class ToolRegistry {
    static let toolSchemaVersion = ToolSchemaVersion.current

    private let todayHealthStateProvider: TodayHealthStateProvider
    private let healthHistoryProvider: HealthHistoryProvider
    private let goalProfileProvider: GoalProfileProvider

    init(
        todayHealthStateProvider: @escaping TodayHealthStateProvider = { _ in nil },
        healthHistoryProvider: @escaping HealthHistoryProvider = { _, _ in [] },
        goalProfileProvider: @escaping GoalProfileProvider = { _ in nil }
    ) {
        self.todayHealthStateProvider = todayHealthStateProvider
        self.healthHistoryProvider = healthHistoryProvider
        self.goalProfileProvider = goalProfileProvider
    }

    var toolDefinitions: [ToolSchema] { allTools.map(\.definition) }

    private var allTools: [any AgentTool] {
        [
            LogMealTool(),
            LogWeightTool(),
            CreateWorkoutPlanTool(),
            CreateTrainingPlanTool(),
            StageDailyCheckInTool(),
            StageUserPreferenceTool(),
            SearchFoodTool(),
            GetMetricsTool(),
            GetWeeklyDeficitTool(),
            SuggestMealPlanTool(),
            GetScheduleTool(),
            GetTodayPlanTool(),
            GetTodayHealthStateTool(stateProvider: todayHealthStateProvider),
            GetHealthHistoryTool(historyProvider: healthHistoryProvider),
            GetPendingActionsTool(),
            GetRecentMealsTool(),
            GetRecentWorkoutsTool(),
            GetRecipePriorTool(),
            GetGoalTool(goalProvider: goalProfileProvider),
            GetUserPreferencesTool(),
        ]
    }

    func execute(
        name: String,
        arguments: JSONValue,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        guard let tool = allTools.first(where: { $0.definition.name == name }) else {
            throw ToolError.unknownTool(name)
        }
        try ToolSchemaValidator.validate(arguments, against: tool.definition.parameters)
        let data = try arguments.encodedData()
        guard let argumentsJSON = String(data: data, encoding: .utf8) else {
            throw ToolError.invalidArguments
        }
        let output = try await tool.execute(
            argumentsJSON: argumentsJSON,
            context: context,
            clientRequestID: clientRequestID
        )
        return AgentToolOutputLimiter.limit(output)
    }

    func effect(for name: String) -> ToolEffect? {
        allTools.first(where: { $0.definition.name == name })?.definition.effect
    }
}

enum AgentToolOutputLimiter {
    static let maximumUTF8Bytes = 8_192

    static func limit(_ output: String) -> String {
        guard output.utf8.count > maximumUTF8Bytes else { return output }
        return #"{"error":{"code":"tool_output_limit_exceeded","message":"Narrow the requested date range or ask for fewer records.","truncated":true}}"#
    }
}

enum ToolError: Equatable, Sendable, SharedErrorDescribing {
    case unknownTool(String)
    case invalidArguments

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .unknownTool:
            SharedErrorDescriptor(
                code: .toolArgumentsInvalid,
                userMessage: "暂时无法处理该请求，请重试。",
                subsystem: .agent,
                reason: .unknownTool
            )
        case .invalidArguments:
            SharedErrorDescriptor(
                code: .toolArgumentsInvalid,
                userMessage: "请求参数暂时无法处理，请重试。",
                subsystem: .agent,
                reason: .invalidToolArguments
            )
        }
    }

    var errorDescription: String? {
        sharedErrorDescriptor.userMessage
    }
}

@MainActor
protocol AgentTool {
    var definition: ToolSchema { get }
    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String
}

@MainActor
protocol ConfirmationRequiredTool: AgentTool {
    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload
}

extension ConfirmationRequiredTool {
    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        let action = try await context.stageAction(
            try await prepare(argumentsJSON: argumentsJSON, context: context),
            clientRequestID: clientRequestID
        )
        let response: JSONValue = .object([
            "actionId": .string(action.id.uuidString.lowercased()),
            "effect": .string(ToolEffect.stagesAction.rawValue),
            "expiresAt": .string(ISO8601DateFormatter().string(from: action.expiresAt)),
            "summary": .string(action.payload.summary),
            "saved": .boolean(false),
        ])
        return String(data: try response.encodedData(), encoding: .utf8) ?? "{}"
    }
}

extension ToolSchema {
    static func strictObject(
        name: String,
        description: String,
        effect: ToolEffect = .readOnly,
        properties: [String: JSONSchemaNode],
        required: [String]
    ) -> ToolSchema {
        ToolSchema(
            name: name,
            description: description,
            effect: effect,
            parameters: .object(
                properties: properties,
                required: required,
                additionalProperties: false
            )
        )
    }
}
