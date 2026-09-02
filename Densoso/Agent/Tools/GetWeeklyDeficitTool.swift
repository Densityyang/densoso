import Foundation

struct GetWeeklyDeficitTool: AgentTool {
    var definition: ToolSchema { .strictObject(
        name: "get_weekly_deficit",
        description: "获取本周（或指定周）的热量缺口汇总。weekOffset=0为本週，-1为上週。",
        properties: [
            "weekOffset": .integer(minimum: -52, maximum: 0, description: "周偏移: 0=本周, -1=上周")
        ],
        required: []
    )}

    func execute(argumentsJSON: String, context: AgentSession, clientRequestID: UUID) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"error": "参数解析失败"}"#
        }

        let offset = json["weekOffset"] as? Int ?? 0

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let mondayOffset = weekday == 1 ? -6 : 2 - weekday
        let monday = calendar.date(byAdding: .day, value: mondayOffset + offset * 7, to: today)!
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!

        let metricsList = try await context.dailyMetrics(from: monday, through: sunday)
        let totalDeficit = metricsList.reduce(0) { $0 + $1.deficitKcal }
        let daysWithData = metricsList.count
        let average = daysWithData == 0 ? 0 : Double(totalDeficit) / Double(daysWithData)

        let formatter = ISO8601DateFormatter()
        let resp: [String: Any] = [
            "weekStart": formatter.string(from: monday),
            "weekEnd": formatter.string(from: sunday),
            "totalDeficitKcal": totalDeficit,
            "avgDailyDeficitKcal": average,
            "projectedWeightLossKg": Double(totalDeficit) / 7_700,
            "daysWithData": daysWithData,
            "totalMeals": metricsList.reduce(0) { $0 + $1.mealCount },
            "totalWorkouts": metricsList.reduce(0) { $0 + $1.workoutCount },
            "bestDayDeficit": metricsList.map(\.deficitKcal).max() ?? 0,
            "worstDayDeficit": metricsList.map(\.deficitKcal).min() ?? 0,
        ]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }
}
