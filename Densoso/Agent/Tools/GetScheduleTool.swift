import Foundation

struct GetScheduleTool: AgentTool {
    var definition: ToolSchema { .strictObject(
        name: "get_schedule",
        description: "获取某日的日程安排。",
        properties: ["date": .string(format: "date-time", description: "日期 ISO8601")],
        required: ["date"]
    )}

    func execute(argumentsJSON: String, context: AgentSession, clientRequestID: UUID) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dateStr = json["date"] as? String else {
            return #"{"error": "日期参数缺失"}"#
        }

        guard let targetDate = Self.parseISO8601Date(dateStr) else {
            return #"{"error": "日期格式错误"}"#
        }

        let events = try await context.schedule(on: targetDate)

        let eventList = events.map { e -> [String: Any] in
            [
                "title": e.title,
                "startTime": ISO8601DateFormatter().string(from: e.startTime),
                "endTime": e.endTime.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "notes": e.notes ?? "",
                "source": e.source.rawValue,
            ]
        }

        let resp: [String: Any] = ["date": dateStr, "events": eventList, "count": eventList.count]
        let respData = try JSONSerialization.data(withJSONObject: resp)
        return String(data: respData, encoding: .utf8) ?? "{}"
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
