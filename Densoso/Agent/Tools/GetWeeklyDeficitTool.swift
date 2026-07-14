import Foundation
import SwiftData

struct GetWeeklyDeficitTool: AgentTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "get_weekly_deficit",
        description: "获取本周（或指定周）的热量缺口汇总。weekOffset=0为本週，-1为上週。",
        properties: [
            ("weekOffset", "integer", "周偏移: 0=本周, -1=上周", false),
        ]
    )}

    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String {
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

        let predicate = #Predicate<DailyMetrics> { m in
            m.date >= monday && m.date <= sunday
        }
        let descriptor = FetchDescriptor<DailyMetrics>(predicate: predicate)
        let metricsList = (try? modelContext.fetch(descriptor)) ?? []

        let summary = CaloricEngine.weeklySummary(dailyMetrics: metricsList)

        let formatter = ISO8601DateFormatter()
        let resp: [String: Any] = [
            "weekStart": formatter.string(from: monday),
            "weekEnd": formatter.string(from: sunday),
            "totalDeficitKcal": summary.totalDeficitKcal,
            "avgDailyDeficitKcal": summary.avgDailyDeficitKcal,
            "projectedWeightLossKg": summary.projectedWeightLossKg,
            "daysWithData": summary.daysWithData,
            "totalMeals": summary.totalMeals,
            "totalWorkouts": summary.totalWorkouts,
            "bestDayDeficit": summary.bestDay?.deficitKcal ?? 0,
            "worstDayDeficit": summary.worstDay?.deficitKcal ?? 0,
        ]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }
}
