import Foundation

@MainActor
struct GetRecentMealsTool: AgentTool {
    static let defaultDayCount = 7
    static let defaultMealCount = 10

    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    var definition: ToolSchema {
        .strictObject(
            name: "get_recent_meals",
            description: "只读查看最近记录的餐食摘要，按用户本地日期从新到旧排序。默认查看近 7 天、最多 10 餐；仅返回餐类、可用的估算范围和菜名。菜品热量仅在可用时返回，未知热量不会用 0 表示；不返回备注、原始食材 JSON、证据数据或存储标识。",
            properties: [
                "days": .integer(
                    minimum: 1,
                    maximum: AgentRecentMealsLimits.maximumDays,
                    description: "查看最近几天，范围 1–30，默认 7；按用户本地自然日计算"
                ),
                "limit": .integer(
                    minimum: 1,
                    maximum: AgentRecentMealsLimits.maximumMealCount,
                    description: "最多返回几餐，范围 1–20，默认 10"
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
            throw GetRecentMealsToolError.invalidArguments
        }
        let days = arguments["days"] as? Int ?? Self.defaultDayCount
        let limit = arguments["limit"] as? Int ?? Self.defaultMealCount
        let window = try queryWindow(days: days, asOf: Date())
        guard (1...AgentRecentMealsLimits.maximumMealCount).contains(limit) else {
            throw GetRecentMealsToolError.invalidLimit
        }
        let meals = try await context.recentMeals(
            from: window.startDate,
            through: window.endDate,
            limit: limit
        )
        return try response(
            meals: meals,
            from: window.startDate,
            through: window.endDate,
            limit: limit
        )
    }

    func queryWindow(days: Int, asOf date: Date) throws -> (startDate: Date, endDate: Date) {
        guard (1...AgentRecentMealsLimits.maximumDays).contains(days) else {
            throw GetRecentMealsToolError.invalidDayCount
        }
        let today = calendar.startOfDay(for: date)
        guard let startDate = calendar.date(byAdding: .day, value: 1 - days, to: today) else {
            throw GetRecentMealsToolError.invalidDayCount
        }
        return (startDate, date)
    }

    func response(
        meals: [AgentRecentMeal],
        from startDate: Date,
        through endDate: Date,
        limit: Int
    ) throws -> String {
        guard startDate <= endDate else { throw GetRecentMealsToolError.invalidRange }
        guard (1...AgentRecentMealsLimits.maximumMealCount).contains(limit) else {
            throw GetRecentMealsToolError.invalidLimit
        }
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard let elapsedDays = calendar.dateComponents([.day], from: startDay, to: endDay).day,
              elapsedDays >= 0,
              elapsedDays < AgentRecentMealsLimits.maximumDays else {
            throw GetRecentMealsToolError.invalidDayCount
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

        let candidates = meals
            .filter { $0.occurredAt >= startDate && $0.occurredAt <= endDate }
            .sorted {
                let lhsDay = calendar.startOfDay(for: $0.occurredAt)
                let rhsDay = calendar.startOfDay(for: $1.occurredAt)
                if lhsDay != rhsDay { return lhsDay > rhsDay }
                return $0.occurredAt > $1.occurredAt
            }
        var hasMore = candidates.count > limit
        var outputMeals = Array(candidates.prefix(limit))
            .map { meal in
                RecentMealOutput(
                    localDate: dateFormatter.string(from: meal.occurredAt),
                    localTime: timeFormatter.string(from: meal.occurredAt),
                    mealType: String(meal.mealType.prefix(AgentRecentMealsLimits.maximumMealTypeLength)),
                    energyEstimate: meal.energyEstimate.map {
                        RecentMealEnergyOutput(
                            lowKcal: $0.lowKcal,
                            likelyKcal: $0.likelyKcal,
                            highKcal: $0.highKcal
                        )
                    },
                    dishes: meal.dishes.prefix(AgentRecentMealsLimits.maximumDishesPerMeal).map {
                        RecentDishOutput(
                            name: String($0.name.prefix(AgentRecentMealsLimits.maximumDishNameLength)),
                            likelyKcal: $0.likelyKcal
                        )
                    }
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let output = RecentMealsToolOutput(
                status: outputMeals.isEmpty ? "noData" : "available",
                startDate: dateFormatter.string(from: startDay),
                endDate: dateFormatter.string(from: endDay),
                returnedCount: outputMeals.count,
                hasMore: hasMore,
                meals: outputMeals
            )
            let serialized = String(decoding: try encoder.encode(output), as: UTF8.self)
            if serialized.count <= AgentRecentMealsLimits.maximumOutputCharacters || outputMeals.isEmpty {
                return serialized
            }
            outputMeals.removeLast()
            hasMore = true
        }
    }
}

private struct RecentMealsToolOutput: Encodable {
    let status: String
    let startDate: String
    let endDate: String
    let returnedCount: Int
    let hasMore: Bool
    let meals: [RecentMealOutput]
}

private struct RecentMealOutput: Encodable {
    let localDate: String
    let localTime: String
    let mealType: String
    let energyEstimate: RecentMealEnergyOutput?
    let dishes: [RecentDishOutput]
}

private struct RecentMealEnergyOutput: Encodable {
    let lowKcal: Double
    let likelyKcal: Double
    let highKcal: Double
}

private struct RecentDishOutput: Encodable {
    let name: String
    let likelyKcal: Int?
}

private enum GetRecentMealsToolError: Error, LocalizedError {
    case invalidArguments
    case invalidDayCount
    case invalidLimit
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "餐食查询参数无法解析。"
        case .invalidDayCount:
            "查询天数必须在 1–30 天内。"
        case .invalidLimit:
            "餐食结果数必须在 1–20 条内。"
        case .invalidRange:
            "结束时间必须晚于或等于开始时间。"
        }
    }
}
