import DensosoDomain
import Foundation

@MainActor
struct GetUserPreferencesTool: AgentTool {
    var definition: ToolSchema {
        .strictObject(
            name: "get_user_preferences",
            description: "只在用户明确询问已记录的个人偏好时调用。只读返回用户确认过的饮食、运动和沟通偏好，不会写入、同步或把结果加入普通上下文。",
            properties: [:],
            required: []
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        let preferences = try await context.userPreferences(
            limit: AgentUserPreferencesLimits.defaultPreferenceCount
        )
        return try response(preferences: preferences)
    }

    func response(
        preferences: [AgentUserPreference],
        limit: Int = AgentUserPreferencesLimits.defaultPreferenceCount
    ) throws -> String {
        guard (1...AgentUserPreferencesLimits.maximumPreferenceCount).contains(limit) else {
            throw GetUserPreferencesToolError.invalidLimit
        }

        var outputPreferences = Array(preferences.prefix(limit)).map { preference in
            UserPreferenceOutput(
                category: preference.category.rawValue,
                statement: String(preference.statement.prefix(AgentUserPreferencesLimits.maximumStatementLength))
            )
        }
        var hasMore = preferences.count > outputPreferences.count
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let output = UserPreferencesToolOutput(
                status: outputPreferences.isEmpty ? "noPreferences" : "available",
                returnedCount: outputPreferences.count,
                hasMore: hasMore,
                preferences: outputPreferences
            )
            let serialized = String(decoding: try encoder.encode(output), as: UTF8.self)
            if serialized.count <= AgentUserPreferencesLimits.maximumOutputCharacters || outputPreferences.isEmpty {
                return serialized
            }
            outputPreferences.removeLast()
            hasMore = true
        }
    }
}

private struct UserPreferencesToolOutput: Encodable {
    let status: String
    let returnedCount: Int
    let hasMore: Bool
    let preferences: [UserPreferenceOutput]
}

private struct UserPreferenceOutput: Encodable {
    let category: String
    let statement: String
}

private enum GetUserPreferencesToolError: Error, LocalizedError {
    case invalidLimit

    var errorDescription: String? {
        "偏好查询结果数超出允许范围。"
    }
}
