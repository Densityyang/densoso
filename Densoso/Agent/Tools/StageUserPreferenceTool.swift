import DensosoDomain
import Foundation

struct StageUserPreferenceTool: ConfirmationRequiredTool {
    var definition: ToolSchema {
        .strictObject(
            name: "stage_user_preference",
            description: "只在用户明确说出饮食、运动或沟通偏好时，为其原意准备待确认草稿。不得从 HealthKit、生理数据、历史行为或模型推断偏好；此工具不会保存，必须由用户确认。",
            effect: .stagesAction,
            properties: [
                "category": .string(allowedValues: UserPreferenceCategory.allCases.map(\.rawValue)),
                "statement": .string(maximumLength: 500),
            ],
            required: ["category", "statement"]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        .userPreference(try draft(argumentsJSON: argumentsJSON, asOf: Date()))
    }

    /// Builds a user-reported domain value without persisting it.
    func draft(argumentsJSON: String, asOf date: Date) throws -> UserPreference {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys).isSubset(of: Set(["category", "statement"])),
              let categoryRaw = json["category"] as? String,
              let category = UserPreferenceCategory(rawValue: categoryRaw),
              let rawStatement = json["statement"] as? String else {
            throw DraftError.invalidUserPreference
        }

        let statement = rawStatement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty, statement.count <= 500 else {
            throw DraftError.invalidUserPreference
        }

        return UserPreference(category: category, statement: statement, createdAt: date)
    }
}
