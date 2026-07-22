import Foundation

struct LogWorkoutTool: ConfirmationRequiredTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "log_workout",
        description: "准备一次运动记录草稿。该工具不会保存数据，必须等待用户确认。",
        properties: [
            ("type", "string", "运动类型: running/walking/cycling/swimming/strength/hiit/yoga/other", true),
            ("durationMinutes", "integer", "时长(分钟)，1 到 1440", true),
            ("intensity", "string", "强度: light/moderate/vigorous", true),
            ("estimatedCalories", "integer", "估计消耗(kcal)，0 到 30000", false),
            ("notes", "string", "备注", false),
        ]
    ) }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> PendingActionPreparation {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let duration = json["durationMinutes"] as? Int,
              let intensity = json["intensity"] as? String else { throw DraftError.invalidWorkout }

        let allowedTypes = Set(["running", "walking", "cycling", "swimming", "strength", "hiit", "yoga", "other"])
        let allowedIntensities = Set(["light", "moderate", "vigorous"])
        guard allowedTypes.contains(type), allowedIntensities.contains(intensity), (1...1_440).contains(duration) else {
            throw DraftError.invalidWorkout
        }
        let calories = json["estimatedCalories"] as? Int ?? 0
        guard (0...30_000).contains(calories) else { throw DraftError.invalidWorkout }
        let notes = (json["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = WorkoutDraft(date: Date(), type: type, durationMinutes: duration, intensity: intensity,
                                 estimatedCalories: calories, notes: notes?.isEmpty == true ? nil : notes)
        return PendingActionPreparation(payload: .workout(draft),
                                        idempotencyKey: PendingActionStore.idempotencyKey(for: argumentsJSON, toolName: definition.name))
    }
}

enum DraftError: LocalizedError {
    case invalidMeal
    case invalidWorkout

    var errorDescription: String? {
        switch self { case .invalidMeal: "餐食草稿字段不完整或超出允许范围"; case .invalidWorkout: "运动草稿字段不完整或超出允许范围" }
    }
}
