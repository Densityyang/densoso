import DensosoDomain
import Foundation

@MainActor
final class ToolRegistry {
    var toolDefinitions: [DeepSeekClient.ToolDef] {
        allTools.map(\.definition)
    }

    private var allTools: [any AgentTool] {
        [
            LogMealTool(),
            LogWeightTool(),
            QueryFoodTool(),
            GetMetricsTool(),
            GetWeeklyDeficitTool(),
            SuggestMealPlanTool(),
            GetScheduleTool(),
        ]
    }

    func execute(
        name: String,
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        guard let tool = allTools.first(where: { $0.definition.name == name }) else {
            throw ToolError.unknownTool(name)
        }
        return try await tool.execute(
            argumentsJSON: argumentsJSON,
            context: context,
            clientRequestID: clientRequestID
        )
    }
}

enum ToolError: Error, LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "未知工具: \(name)"
        }
    }
}

@MainActor
protocol AgentTool {
    var definition: DeepSeekClient.ToolDef { get }
    var effect: ToolEffect { get }
    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String
}

extension AgentTool {
    var effect: ToolEffect { .readOnly }
}

@MainActor
protocol ConfirmationRequiredTool: AgentTool {
    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload
}

extension ConfirmationRequiredTool {
    var effect: ToolEffect { .stagesAction }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        let action = try await context.stageAction(
            try await prepare(argumentsJSON: argumentsJSON, context: context),
            clientRequestID: clientRequestID
        )
        let response: [String: Any] = [
            "actionId": action.id.uuidString,
            "effect": ToolEffect.stagesAction.rawValue,
            "expiresAt": ISO8601DateFormatter().string(from: action.expiresAt),
            "summary": action.payload.summary,
            "saved": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        return String(data: data, encoding: .utf8) ?? #"{"error":"确认草稿编码失败"}"#
    }
}

extension DeepSeekClient.ToolDef {
    static func make(
        name: String,
        description: String,
        properties: [(String, String, String, Bool)]
    ) -> DeepSeekClient.ToolDef {
        var props: [String: DeepSeekClient.PropertySchema] = [:]
        var required: [String] = []
        for (key, type, description, isRequired) in properties {
            props[key] = DeepSeekClient.PropertySchema(type: type, description: description)
            if isRequired { required.append(key) }
        }
        return DeepSeekClient.ToolDef(
            name: name,
            description: description,
            inputSchema: DeepSeekClient.JSONSchema(
                type: "object",
                properties: props,
                required: required.isEmpty ? nil : required
            )
        )
    }
}
