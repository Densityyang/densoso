import Foundation
import SwiftData

struct GetScheduleTool: AgentTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "get_schedule",
        description: "获取某日的日程安排。",
        properties: [
            ("date", "string", "日期 ISO8601", true),
        ]
    )}

    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dateStr = json["date"] as? String else {
            return #"{"error": "日期参数缺失"}"#
        }

        let formatter = ISO8601DateFormatter()
        guard let targetDate = formatter.date(from: dateStr) else {
            return #"{"error": "日期格式错误"}"#
        }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: targetDate)
        let endDay = calendar.date(byAdding: .day, value: 1, to: startDay)!

        let predicate = #Predicate<ScheduleEvent> { e in
            e.date >= startDay && e.date < endDay
        }
        let descriptor = FetchDescriptor<ScheduleEvent>(predicate: predicate)
        let events = (try? modelContext.fetch(descriptor)) ?? []

        let eventList = events.map { e -> [String: Any] in
            [
                "title": e.title,
                "startTime": ISO8601DateFormatter().string(from: e.startTime),
                "endTime": e.endTime.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "notes": e.notes ?? "",
            ]
        }

        let resp: [String: Any] = ["date": dateStr, "events": eventList, "count": eventList.count]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }
}
