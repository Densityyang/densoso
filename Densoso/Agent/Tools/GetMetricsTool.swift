import DensosoDomain
import Foundation

struct GetMetricsTool: AgentTool {
    private static let maximumRangeDays = 90
    private static let dailyBreakdownPageSize = 4

    var definition: ToolSchema { .strictObject(
        name: "get_metrics",
        description: "获取最多 90 天的热量与营养汇总；每项结果包含可用状态和覆盖率。日期按用户本地日历日闭区间处理。dailyBreakdown 最多返回 4 天，并包含每日覆盖率、能量质量、待重算状态和投影版本；为控制输出大小，必要时会缩小当前页，truncated=true 时可从 nextStartDate 继续查询。projectedWeightLossKg 仅为粗略能量折算，并附非体重预测说明。",
        properties: [
            "startDate": .string(format: "date-time", description: "开始日期 ISO8601，按本地日历日包含"),
            "endDate": .string(format: "date-time", description: "结束日期 ISO8601，按本地日历日包含"),
        ],
        required: ["startDate", "endDate"]
    )}

    func execute(argumentsJSON: String, context: AgentSession, clientRequestID: UUID) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startString = json["startDate"] as? String,
              let endString = json["endDate"] as? String,
              let startDate = Self.parseDate(startString),
              let endDate = Self.parseDate(endString) else {
            return #"{"error":{"code":"invalid_arguments","message":"startDate and endDate must be ISO8601 dates."}}"#
        }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard startDay <= endDay else {
            return #"{"error":{"code":"invalid_range","message":"startDate must be on or before endDate."}}"#
        }
        let dayDifference = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? Int.max
        let requestedDays = dayDifference == Int.max ? Int.max : dayDifference + 1
        guard requestedDays <= Self.maximumRangeDays else {
            return #"{"error":{"code":"range_too_large","maximumDays":90}}"#
        }

        let metrics = try await context.dailyMetrics(from: startDay, through: endDay)
        return Self.responseJSON(metrics, from: startDay, through: endDay, calendar: calendar)
    }

    static func responseJSON(
        _ metrics: [DailyMetricsReadResult],
        from startDay: Date,
        through endDay: Date,
        calendar: Calendar
    ) -> String {
        let dayDifference = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? Int.max
        let requestedDays = dayDifference == Int.max ? Int.max : dayDifference + 1
        let intake = DailyMetricsUsabilityPolicy.aggregateRanges(metrics.map(\.intake), expectedDays: requestedDays)
        let expenditure = DailyMetricsUsabilityPolicy.aggregateRanges(metrics.map(\.expenditure), expectedDays: requestedDays)
        let deficit = DailyMetricsUsabilityPolicy.aggregateSignedRanges(metrics.map(\.deficit), expectedDays: requestedDays)
        let proteinTotal = DailyMetricsUsabilityPolicy.aggregateNumbers(
            metrics.map(\.proteinG), expectedDays: requestedDays
        )
        let proteinAverage = DailyMetricsUsabilityPolicy.aggregateNumbers(
            metrics.map(\.proteinG), expectedDays: requestedDays, average: true
        )
        let fatTotal = DailyMetricsUsabilityPolicy.aggregateNumbers(metrics.map(\.fatG), expectedDays: requestedDays)
        let fatAverage = DailyMetricsUsabilityPolicy.aggregateNumbers(
            metrics.map(\.fatG), expectedDays: requestedDays, average: true
        )
        let carbsTotal = DailyMetricsUsabilityPolicy.aggregateNumbers(metrics.map(\.carbsG), expectedDays: requestedDays)
        let carbsAverage = DailyMetricsUsabilityPolicy.aggregateNumbers(
            metrics.map(\.carbsG), expectedDays: requestedDays, average: true
        )
        let averageDeficit = Self.average(deficit)
        let projectedWeightLoss = Self.projectedWeightLoss(from: deficit.total)
        var lastOutput = "{}"
        let maximumPageSize = min(metrics.count, Self.dailyBreakdownPageSize)
        let minimumPageSize = metrics.isEmpty ? 0 : 1
        for pageSize in stride(from: maximumPageSize, through: minimumPageSize, by: -1) {
            let response = GetMetricsToolResponse(
                status: deficit.coverage.availableDays == 0 ? "insufficient_data" : "available",
                startDate: startDay,
                endDate: endDay,
                timeZone: calendar.timeZone.identifier,
                requestedDays: requestedDays,
                validEnergyDays: deficit.coverage.availableDays,
                missingEnergyDays: max(requestedDays - deficit.coverage.availableDays, 0),
                intake: intake,
                expenditure: expenditure,
                deficit: deficit,
                averageDailyDeficit: averageDeficit,
                projectedWeightLossKg: projectedWeightLoss,
                projectedWeightLossNote: "仅按累计净能量缺口以 7,700 kcal/kg 粗略折算；不代表实际体重预测。",
                proteinG: NutrientAggregate(total: proteinTotal, average: proteinAverage),
                fatG: NutrientAggregate(total: fatTotal, average: fatAverage),
                carbsG: NutrientAggregate(total: carbsTotal, average: carbsAverage),
                dailyBreakdown: metrics.prefix(pageSize).map(DailyMetricBreakdown.init),
                truncated: metrics.count > pageSize,
                nextStartDate: metrics.count > pageSize ? metrics[pageSize].date : nil
            )
            let output = Self.encode(response)
            guard output.utf8.count > AgentToolOutputLimiter.maximumUTF8Bytes else { return output }
            lastOutput = output
        }
        return AgentToolOutputLimiter.limit(lastOutput)
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func average(_ aggregate: MetricAggregate<SignedEstimateRange>) -> MetricValue<SignedEstimateRange> {
        guard let total = aggregate.total.value,
              let value = total.divided(by: aggregate.coverage.availableDays) else {
            return MetricValue(value: nil, availability: aggregate.total.availability)
        }
        return MetricValue(
            value: value,
            availability: aggregate.total.availability,
            sourceReferences: aggregate.total.sourceReferences,
            sourceReferencesTruncated: aggregate.total.sourceReferencesTruncated
        )
    }

    private static func projectedWeightLoss(
        from deficit: MetricValue<SignedEstimateRange>
    ) -> MetricValue<Double> {
        guard let value = deficit.value else {
            return MetricValue(value: nil, availability: deficit.availability)
        }
        return MetricValue(
            value: value.likely / 7_700,
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

private struct NutrientAggregate: Encodable {
    let total: MetricValue<Double>
    let average: MetricValue<Double>
    let coverage: MetricCoverage

    init(total: MetricAggregate<Double>, average: MetricAggregate<Double>) {
        self.total = total.total
        self.average = average.total
        coverage = total.coverage
    }
}

private struct DailyMetricBreakdown: Encodable {
    let date: Date
    let intake: MetricValue<EstimateRange>
    let expenditure: MetricValue<EstimateRange>
    let deficit: MetricValue<SignedEstimateRange>
    let proteinG: MetricValue<Double>
    let fatG: MetricValue<Double>
    let carbsG: MetricValue<Double>
    let coverage: DailyMetricCoverage
    let energyQuality: EnergyQuality
    let requiresRecompute: Bool
    let projectionVersion: String

    init(_ result: DailyMetricsReadResult) {
        date = result.date
        intake = result.intake
        expenditure = result.expenditure
        deficit = result.deficit
        proteinG = result.proteinG
        fatG = result.fatG
        carbsG = result.carbsG
        coverage = result.coverage
        energyQuality = result.energyQuality
        requiresRecompute = result.requiresRecompute
        projectionVersion = result.projectionVersion
    }
}

private struct GetMetricsToolResponse: Encodable {
    let status: String
    let startDate: Date
    let endDate: Date
    let timeZone: String
    let requestedDays: Int
    let validEnergyDays: Int
    let missingEnergyDays: Int
    let intake: MetricAggregate<EstimateRange>
    let expenditure: MetricAggregate<EstimateRange>
    let deficit: MetricAggregate<SignedEstimateRange>
    let averageDailyDeficit: MetricValue<SignedEstimateRange>
    let projectedWeightLossKg: MetricValue<Double>
    let projectedWeightLossNote: String
    let proteinG: NutrientAggregate
    let fatG: NutrientAggregate
    let carbsG: NutrientAggregate
    let dailyBreakdown: [DailyMetricBreakdown]
    let truncated: Bool
    let nextStartDate: Date?
}
