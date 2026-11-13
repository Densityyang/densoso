import Foundation

@MainActor
struct GetRecentWorkoutsTool: AgentTool {
    static let defaultDayCount = 7
    static let defaultWorkoutCount = 10

    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    var definition: ToolSchema {
        .strictObject(
            name: "get_recent_workouts",
            description: "只读查看最近已记录完成的运动摘要，按用户本地日期从新到旧排序。计划日程不会作为已完成运动返回。默认查看近 7 天、最多 10 项；不返回备注、HealthKit 原始样本或存储标识。",
            properties: [
                "days": .integer(
                    minimum: 1,
                    maximum: AgentRecentWorkoutsLimits.maximumDays,
                    description: "查看最近几天，范围 1–30，默认 7；按用户本地自然日计算"
                ),
                "limit": .integer(
                    minimum: 1,
                    maximum: AgentRecentWorkoutsLimits.maximumWorkoutCount,
                    description: "最多返回几项已记录运动，范围 1–20，默认 10"
                ),
            ],
            required: []
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GetRecentWorkoutsToolError.invalidArguments
        }
        let days = arguments["days"] as? Int ?? Self.defaultDayCount
        let limit = arguments["limit"] as? Int ?? Self.defaultWorkoutCount
        let window = try queryWindow(days: days, asOf: Date())
        guard (1...AgentRecentWorkoutsLimits.maximumWorkoutCount).contains(limit) else {
            throw GetRecentWorkoutsToolError.invalidLimit
        }
        let workouts = try await context.recentWorkouts(
            from: window.startDate,
            through: window.endDate,
            limit: limit
        )
        return try response(
            workouts: workouts,
            from: window.startDate,
            through: window.endDate,
            limit: limit
        )
    }

    func queryWindow(days: Int, asOf date: Date) throws -> (startDate: Date, endDate: Date) {
        guard (1...AgentRecentWorkoutsLimits.maximumDays).contains(days) else {
            throw GetRecentWorkoutsToolError.invalidDayCount
        }
        let today = calendar.startOfDay(for: date)
        guard let startDate = calendar.date(byAdding: .day, value: 1 - days, to: today) else {
            throw GetRecentWorkoutsToolError.invalidDayCount
        }
        return (startDate, date)
    }

    func response(
        workouts: [AgentRecentWorkout],
        from startDate: Date,
        through endDate: Date,
        limit: Int
    ) throws -> String {
        guard startDate <= endDate else { throw GetRecentWorkoutsToolError.invalidRange }
        guard (1...AgentRecentWorkoutsLimits.maximumWorkoutCount).contains(limit) else {
            throw GetRecentWorkoutsToolError.invalidLimit
        }
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard let elapsedDays = calendar.dateComponents([.day], from: startDay, to: endDay).day,
              elapsedDays >= 0,
              elapsedDays < AgentRecentWorkoutsLimits.maximumDays else {
            throw GetRecentWorkoutsToolError.invalidDayCount
        }

        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm"

        let candidates = workouts
            .filter { $0.occurredAt >= startDate && $0.occurredAt <= endDate }
            .sorted {
                let lhsDay = calendar.startOfDay(for: $0.occurredAt)
                let rhsDay = calendar.startOfDay(for: $1.occurredAt)
                if lhsDay != rhsDay { return lhsDay > rhsDay }
                return $0.occurredAt > $1.occurredAt
            }
        var hasMore = candidates.count > limit
        var outputWorkouts = Array(candidates.prefix(limit)).map { workout in
            RecentWorkoutOutput(
                localDate: dateFormatter.string(from: workout.occurredAt),
                localTime: timeFormatter.string(from: workout.occurredAt),
                workoutType: String(workout.workoutType.prefix(AgentRecentWorkoutsLimits.maximumWorkoutTypeLength)),
                durationMinutes: max(workout.durationMinutes, 0),
                intensity: String(workout.intensity.prefix(AgentRecentWorkoutsLimits.maximumIntensityLength)),
                estimatedCaloriesKcal: workout.estimatedCaloriesKcal.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let output = RecentWorkoutsToolOutput(
                status: outputWorkouts.isEmpty ? "noData" : "available",
                startDate: dateFormatter.string(from: startDay),
                endDate: dateFormatter.string(from: endDay),
                returnedCount: outputWorkouts.count,
                hasMore: hasMore,
                workouts: outputWorkouts
            )
            let serialized = String(decoding: try encoder.encode(output), as: UTF8.self)
            if serialized.count <= AgentRecentWorkoutsLimits.maximumOutputCharacters || outputWorkouts.isEmpty {
                return serialized
            }
            outputWorkouts.removeLast()
            hasMore = true
        }
    }
}

private struct RecentWorkoutsToolOutput: Encodable {
    let status: String
    let startDate: String
    let endDate: String
    let returnedCount: Int
    let hasMore: Bool
    let workouts: [RecentWorkoutOutput]
}

private struct RecentWorkoutOutput: Encodable {
    let localDate: String
    let localTime: String
    let workoutType: String
    let durationMinutes: Int
    let intensity: String
    let estimatedCaloriesKcal: Int?
}

private enum GetRecentWorkoutsToolError: Error, LocalizedError {
    case invalidArguments
    case invalidDayCount
    case invalidLimit
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "运动查询参数无法解析。"
        case .invalidDayCount:
            "查询天数必须在 1–30 天内。"
        case .invalidLimit:
            "运动结果数必须在 1–20 项内。"
        case .invalidRange:
            "结束时间必须晚于或等于开始时间。"
        }
    }
}
