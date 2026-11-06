import DensosoDomain
import Foundation

struct GetWeeklyDeficitTool: AgentTool {
    var definition: ToolSchema { .strictObject(
        name: "get_weekly_deficit",
        description: "获取本周或指定历史周的热量缺口，返回有效天数、缺失天数、可用状态、覆盖率和投影版本（混合时列出版本集合）；本周只统计截至今天的日期。projectedWeightLossKg 仅为粗略能量折算，并附非体重预测说明。",
        properties: [
            "weekOffset": .integer(minimum: -52, maximum: 0, description: "周偏移: 0=本周, -1=上周")
        ],
        required: []
    )}

    func execute(argumentsJSON: String, context: AgentSession, clientRequestID: UUID) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"error":{"code":"invalid_arguments","message":"weekOffset must be an integer."}}"#
        }
        let offset: Int
        if let suppliedOffset = json["weekOffset"] {
            guard let parsedOffset = suppliedOffset as? Int else {
                return #"{"error":{"code":"invalid_arguments","message":"weekOffset must be an integer."}}"#
            }
            offset = parsedOffset
        } else {
            offset = 0
        }
        guard (-52...0).contains(offset) else {
            return #"{"error":{"code":"invalid_range","minimumWeekOffset":-52,"maximumWeekOffset":0}}"#
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let mondayOffset = weekday == 1 ? -6 : 2 - weekday
        guard let monday = calendar.date(byAdding: .day, value: mondayOffset + offset * 7, to: today),
              let sunday = calendar.date(byAdding: .day, value: 6, to: monday) else {
            return #"{"error":{"code":"invalid_calendar_range"}}"#
        }

        let queryEnd = offset == 0 ? today : sunday
        let expectedDays = offset == 0
            ? (calendar.dateComponents([.day], from: monday, to: today).day ?? 0) + 1
            : 7
        let metrics = try await context.dailyMetrics(from: monday, through: queryEnd)
        return Self.responseJSON(
            metrics,
            weekStart: monday,
            weekEnd: queryEnd,
            expectedDays: expectedDays,
            calendar: calendar
        )
    }

    static func responseJSON(
        _ metrics: [DailyMetricsReadResult],
        weekStart: Date,
        weekEnd: Date,
        expectedDays: Int,
        calendar: Calendar
    ) -> String {
        let deficit = DailyMetricsUsabilityPolicy.aggregateSignedRanges(
            metrics.map(\.deficit),
            expectedDays: expectedDays
        )
        let average = Self.average(deficit)
        let projectedWeightLoss = Self.projectedWeightLoss(from: deficit.total)
        let validDeficits = metrics.compactMap { metric -> (Date, Double)? in
            guard let value = metric.deficit.value,
                  metric.deficit.availability == .observed
                    || metric.deficit.availability == .estimated
                    || metric.deficit.availability == .partial else { return nil }
            return (metric.date, value.likely)
        }
        let bestDay = validDeficits.max(by: { $0.1 < $1.1 })
        let worstDay = validDeficits.min(by: { $0.1 < $1.1 })
        let response = WeeklyDeficitToolResponse(
            status: deficit.coverage.availableDays == 0 ? "insufficient_data" : "available",
            weekStart: weekStart,
            weekEnd: weekEnd,
            timeZone: calendar.timeZone.identifier,
            requestedDays: expectedDays,
            daysWithData: deficit.coverage.availableDays,
            missingDays: max(expectedDays - deficit.coverage.availableDays, 0),
            coverage: deficit.coverage,
            projectionVersion: Self.projectionVersion(for: metrics),
            projectionVersions: Self.projectionVersions(for: metrics),
            totalDeficitKcal: Self.likelyValue(from: deficit.total),
            avgDailyDeficitKcal: Self.likelyValue(from: average),
            projectedWeightLossKg: projectedWeightLoss,
            projectedWeightLossNote: "仅按累计净能量缺口以 7,700 kcal/kg 粗略折算；不代表实际体重预测。",
            bestDay: bestDay.map { DatedDeficit(date: $0.0, deficitKcal: $0.1) },
            worstDay: worstDay.map { DatedDeficit(date: $0.0, deficitKcal: $0.1) },
            totalMeals: metrics.reduce(0) { $0 + $1.mealCount },
            totalWorkouts: metrics.reduce(0) { $0 + $1.workoutCount }
        )
        return Self.encode(response)
    }

    private static func projectionVersions(for metrics: [DailyMetricsReadResult]) -> [String] {
        let versions = metrics.map { metric -> String in
            let version = metric.projectionVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            return version.isEmpty ? "unknown" : version
        }
        return Array(Set(versions)).sorted()
    }

    private static func projectionVersion(for metrics: [DailyMetricsReadResult]) -> String {
        let versions = projectionVersions(for: metrics)
        switch versions.count {
        case 0: return "unavailable"
        case 1: return versions[0]
        default: return "mixed"
        }
    }

    private static func average(
        _ aggregate: MetricAggregate<SignedEstimateRange>
    ) -> MetricValue<SignedEstimateRange> {
        guard let total = aggregate.total.value,
              let average = total.divided(by: aggregate.coverage.availableDays) else {
            return MetricValue(value: nil, availability: aggregate.total.availability)
        }
        return MetricValue(
            value: average,
            availability: aggregate.total.availability,
            sourceReferences: aggregate.total.sourceReferences,
            sourceReferencesTruncated: aggregate.total.sourceReferencesTruncated
        )
    }

    private static func likelyValue(from value: MetricValue<SignedEstimateRange>) -> MetricValue<Double> {
        MetricValue(
            value: value.value?.likely,
            availability: value.availability,
            sourceReferences: value.sourceReferences,
            sourceReferencesTruncated: value.sourceReferencesTruncated
        )
    }

    private static func projectedWeightLoss(
        from deficit: MetricValue<SignedEstimateRange>
    ) -> MetricValue<Double> {
        MetricValue(
            value: deficit.value.map { $0.likely / 7_700 },
            availability: deficit.availability,
            sourceReferences: deficit.sourceReferences,
            sourceReferencesTruncated: deficit.sourceReferencesTruncated
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":"encoding_failed"}}"#
        }
        return string
    }
}

private struct DatedDeficit: Encodable {
    let date: Date
    let deficitKcal: Double
}

private struct WeeklyDeficitToolResponse: Encodable {
    let status: String
    let weekStart: Date
    let weekEnd: Date
    let timeZone: String
    let requestedDays: Int
    let daysWithData: Int
    let missingDays: Int
    let coverage: MetricCoverage
    /// A version, "mixed", or "unavailable" when no daily projections were returned.
    let projectionVersion: String
    /// Sorted distinct source versions, preserving detail for mixed-version windows.
    let projectionVersions: [String]
    let totalDeficitKcal: MetricValue<Double>
    let avgDailyDeficitKcal: MetricValue<Double>
    let projectedWeightLossKg: MetricValue<Double>
    let projectedWeightLossNote: String
    let bestDay: DatedDeficit?
    let worstDay: DatedDeficit?
    let totalMeals: Int
    let totalWorkouts: Int
}
