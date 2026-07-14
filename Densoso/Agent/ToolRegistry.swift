import Foundation

/// 工具注册中心
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

protocol AgentTool {
    var definition: DeepSeekClient.ToolDef { get }
    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String
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
