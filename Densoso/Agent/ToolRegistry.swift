import DensosoDomain
import Foundation

@MainActor
final class ToolRegistry {
    var toolDefinitions: [ToolSchema] { allTools.map(\.definition) }

    private var allTools: [any AgentTool] {
        [
            LogMealTool(),
            LogWeightTool(),
            CreateWorkoutPlanTool(),
            QueryFoodTool(),
            GetMetricsTool(),
            GetWeeklyDeficitTool(),
            SuggestMealPlanTool(),
            GetScheduleTool(),
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
        return String(output.prefix(8_192))
    }

    func effect(for name: String) -> ToolEffect? {
        allTools.first(where: { $0.definition.name == name })?.definition.effect
    }
}

enum ToolError: Error, LocalizedError {
    case unknownTool(String)
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "未知工具: \(name)"
        case .invalidArguments: "工具参数无法编码"
        }
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
