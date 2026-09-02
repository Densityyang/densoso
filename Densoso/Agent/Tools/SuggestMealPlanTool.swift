import Foundation

struct SuggestMealPlanTool: AgentTool {
    var definition: ToolSchema { .strictObject(
        name: "suggest_meal_plan",
        description: "根据剩余可摄入热量和用户偏好生成餐单建议。",
        properties: [
            "targetCaloriesPerDay": .integer(minimum: 800, maximum: 5_000, description: "每日目标摄入热量(kcal)"),
            "remainingDays": .integer(minimum: 1, maximum: 30, description: "剩余天数，默认7"),
            "preferences": .string(maximumLength: 500, description: "口味偏好或忌口"),
        ],
        required: ["targetCaloriesPerDay"]
    )}

    func execute(argumentsJSON: String, context: AgentSession, clientRequestID: UUID) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"error": "参数解析失败"}"#
        }

        let targetCal = json["targetCaloriesPerDay"] as? Int ?? 1800
        let days = json["remainingDays"] as? Int ?? 7
        let prefs = json["preferences"] as? String ?? "均衡"

        let breakfast = Int(round(Double(targetCal) * 0.3))
        let lunch = Int(round(Double(targetCal) * 0.4))
        let dinner = Int(round(Double(targetCal) * 0.3))

        let resp: [String: Any] = [
            "targetCaloriesPerDay": targetCal,
            "remainingDays": days,
            "preferences": prefs,
            "mealDistribution": [
                "breakfast": breakfast,
                "lunch": lunch,
                "dinner": dinner,
            ],
            "dailyDeficitToLose": 500,
            "note": "以上为餐单热量框架，请根据 preferences 和食材库数据填充具体菜品建议。",
        ]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }
}
