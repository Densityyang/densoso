import Foundation
import SwiftData

/// 工具注册中心
@MainActor
final class ToolRegistry {
    weak var foodDatabase: FoodDatabase?

    var toolDefinitions: [DeepSeekClient.ToolDef] {
        allTools.map { $0.definition }
    }

    private var allTools: [any AgentTool] {
        [
            LogMealTool(),
            LogWorkoutTool(),
            QueryFoodTool(),
            GetMetricsTool(),
            GetWeeklyDeficitTool(),
            SuggestMealPlanTool(),
            GetScheduleTool(),
        ]
    }

    @MainActor
    func execute(name: String, argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String {
        guard let tool = allTools.first(where: { $0.definition.name == name }) else {
            throw ToolError.unknownTool(name)
        }
        return try await tool.execute(argumentsJSON: argumentsJSON, context: context, modelContext: modelContext)
    }
}

enum ToolError: Error, LocalizedError {
    case unknownTool(String)
    var errorDescription: String? {
        switch self {
        case .unknownTool(let n): "未知工具: \(n)"
        }
    }
}

@MainActor protocol AgentTool {
    var definition: DeepSeekClient.ToolDef { get }
    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String
}

extension AgentTool {
    var effect: ToolEffect { .readOnly }
}

/// 写入类工具只能准备待确认操作；它们不接收持久化上下文。
@MainActor protocol ConfirmationRequiredTool: AgentTool {
    func prepare(argumentsJSON: String, context: AgentSession) async throws -> PendingActionPreparation
}

extension ConfirmationRequiredTool {
    var effect: ToolEffect { .requiresConfirmation }

    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String {
        let action = try context.enqueuePendingAction(try await prepare(argumentsJSON: argumentsJSON, context: context))
        let response: [String: Any] = [
            "actionId": action.id.uuidString,
            "effect": ToolEffect.requiresConfirmation.rawValue,
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
        for (key, type, desc, req) in properties {
            props[key] = DeepSeekClient.PropertySchema(type: type, description: desc)
            if req { required.append(key) }
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
