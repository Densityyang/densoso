import Foundation

struct GetMetricsTool: AgentTool {
    var definition: ToolSchema { .strictObject(
        name: "get_metrics",
        description: "获取任意日期范围内的热量指标：总消耗、摄入、缺口、营养素。",
        properties: [
            "startDate": .string(format: "date-time", description: "开始日期 ISO8601"),
            "endDate": .string(format: "date-time", description: "结束日期 ISO8601"),
        ],
        required: ["startDate", "endDate"]
    )}

    func execute(argumentsJSON: String, context: AgentSession, clientRequestID: UUID) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startStr = json["startDate"] as? String,
              let endStr = json["endDate"] as? String else {
            return #"{"error": "日期参数缺失"}"#
        }

        let formatter = ISO8601DateFormatter()
        guard let startDate = formatter.date(from: startStr),
              let endDate = formatter.date(from: endStr) else {
            return #"{"error": "日期格式错误，请使用 ISO8601"}"#
        }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)

        let metricsList = try await context.dailyMetrics(from: startDay, through: endDay)

        let totalDeficit = metricsList.map(\.deficitKcal).reduce(0, +)
        let totalIntake = metricsList.map(\.intakeKcal).reduce(0, +)
        let totalExpenditure = metricsList.map(\.expenditureKcal).reduce(0, +)
        let days = metricsList.count

        let resp: [String: Any] = [
            "days": days,
            "totalDeficitKcal": totalDeficit,
            "totalIntakeKcal": totalIntake,
            "totalExpenditureKcal": totalExpenditure,
            "avgDailyDeficit": days > 0 ? Double(totalDeficit) / Double(days) : 0,
            "projectedWeightLossKg": Double(totalDeficit) / 7700.0,
            "dailyBreakdown": metricsList.map { m in
                ["date": ISO8601DateFormatter().string(from: m.date),
                 "deficit": m.deficitKcal,
                 "intake": m.intakeKcal,
                 "expenditure": m.expenditureKcal]
            },
        ]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }
}
