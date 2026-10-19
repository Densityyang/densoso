import Foundation

@MainActor
struct GetTodayPlanTool: AgentTool {
    static let maximumEvents = 12
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    var definition: ToolSchema {
        .strictObject(
            name: "get_today_plan",
            description: "只读查看今天已确认的安排；无安排时明确返回空列表，不会推测或创建计划。",
            properties: [:],
            required: []
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        let now = Date()
        let events = try await context.schedule(on: now)
        return try response(asOf: now, items: events)
    }

    func response(asOf date: Date, items: [AgentScheduleItem]) throws -> String {
        let ordered = items.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.title < $1.title
        }
        let selected = ordered.prefix(Self.maximumEvents)
        let output = TodayPlanToolOutput(
            status: selected.isEmpty ? "empty" : "available",
            localDate: localDateString(date),
            count: selected.count,
            hasMore: ordered.count > Self.maximumEvents,
            plans: selected.map { event in
                TodayPlanItemOutput(
                    title: String(event.title.prefix(60)),
                    startTime: ISO8601DateFormatter().string(from: event.startTime),
                    endTime: event.endTime.map { ISO8601DateFormatter().string(from: $0) },
                    summary: event.notes.map { String($0.prefix(80)) }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    private func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct TodayPlanToolOutput: Encodable {
    let status: String
    let localDate: String
    let count: Int
    let hasMore: Bool
    let plans: [TodayPlanItemOutput]
}

private struct TodayPlanItemOutput: Encodable {
    let title: String
    let startTime: String
    let endTime: String?
    let summary: String?
}
