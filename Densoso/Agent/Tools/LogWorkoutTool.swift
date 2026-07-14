import Foundation
import SwiftData

struct LogWorkoutTool: AgentTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "log_workout",
        description: "记录一次运动。根据运动类型/时长/强度估算消耗热量。",
        properties: [
            ("type", "string", "运动类型: running/walking/cycling/swimming/strength/hiit/yoga/other", true),
            ("durationMinutes", "integer", "时长(分钟)", true),
            ("intensity", "string", "强度: light/moderate/vigorous", true),
            ("estimatedCalories", "integer", "估计消耗(kcal)，按 MET×体重×时长估算", false),
            ("notes", "string", "备注", false),
        ]
    )}

    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"error": "参数解析失败"}"#
        }

        let type = json["type"] as? String ?? "other"
        let durationMinutes = json["durationMinutes"] as? Int ?? 0
        let intensity = json["intensity"] as? String ?? "moderate"
        let estimatedCal = json["estimatedCalories"] as? Int ?? 0
        let notes = json["notes"] as? String

        let record = WorkoutRecord(
            date: Date(),
            type: type,
            durationMinutes: durationMinutes,
            estimatedCaloriesBurned: estimatedCal,
            intensity: intensity,
            notes: notes
        )

        modelContext.insert(record)
        try modelContext.save()

        let resp: [String: Any] = [
            "workoutId": record.id.uuidString,
            "type": type,
            "durationMinutes": durationMinutes,
            "estimatedCalories": estimatedCal,
            "saved": true,
        ]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }
}