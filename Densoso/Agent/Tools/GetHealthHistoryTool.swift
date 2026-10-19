import DensosoDomain
import Foundation

typealias HealthHistoryProvider = @Sendable (Date, Date) async throws -> [HealthStateHistoryPoint]

@MainActor
struct GetHealthHistoryTool: AgentTool {
    private let historyProvider: HealthHistoryProvider
    private let calendar: Calendar

    init(
        calendar: Calendar = .current,
        historyProvider: @escaping HealthHistoryProvider = { _, _ in [] }
    ) {
        self.calendar = calendar
        self.historyProvider = historyProvider
    }

    var definition: ToolSchema {
        .strictObject(
            name: "get_health_history",
            description: "读取最多连续 14 天的每日健康状态汇总，用于查看与个人近期基线的变化。仅返回聚合状态和有证据支持的数值，不返回 HealthKit 原始样本；缺失数据不会按零处理，也不提供医学诊断。",
            properties: [
                "startDate": .string(format: "date-time", description: "开始日期 ISO8601，按用户本地日期取整"),
                "endDate": .string(format: "date-time", description: "结束日期 ISO8601，包含该本地日期；不能晚于今天"),
            ],
            required: ["startDate", "endDate"]
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startValue = arguments["startDate"] as? String,
              let endValue = arguments["endDate"] as? String,
              let startDate = Self.parseDate(startValue),
              let endDate = Self.parseDate(endValue) else {
            throw GetHealthHistoryToolError.invalidDates
        }

        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        try Self.validateRange(start: startDay, end: endDay, calendar: calendar)
        let points = try await historyProvider(startDay, endDay)
        return try response(
            from: startDay,
            through: endDay,
            points: points
        )
    }

    func response(
        from startDate: Date,
        through endDate: Date,
        points: [HealthStateHistoryPoint]
    ) throws -> String {
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        try Self.validateRange(start: startDay, end: endDay, calendar: calendar)

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let dailySummaries = points
            .filter { $0.date >= startDay && $0.date <= endDay }
            .sorted { $0.date < $1.date }
            .map { point in
                let domainStatuses = Dictionary(uniqueKeysWithValues: point.state.domains.map {
                    ($0.domain.rawValue, $0.status.rawValue)
                })
                var observations: [String: Double] = [:]
                for domain in point.state.domains {
                    guard let value = domain.currentValue,
                          let key = domain.evidenceKeys.first,
                          value.isFinite else { continue }
                    observations[key] = value
                }
                if let ratio = point.state.trainingLoad.ratio, ratio.isFinite {
                    observations["trainingLoad.ratio"] = ratio
                }
                return HealthHistoryDayOutput(
                    date: formatter.string(from: point.date),
                    domainStatuses: domainStatuses,
                    observations: observations,
                    recoveryStatus: point.state.recovery.status.rawValue,
                    trainingLoadBand: point.state.trainingLoad.band.rawValue
                )
            }

        let hasObservations = dailySummaries.contains { !$0.observations.isEmpty }
        let hasGaps = dailySummaries.contains { summary in
            summary.domainStatuses.values.contains("noData")
                || summary.domainStatuses.values.contains("learning")
                || summary.recoveryStatus == RecoveryStatus.insufficientEvidence.rawValue
        }
        let status: HealthHistoryToolStatus
        if !hasObservations {
            status = .noData
        } else if hasGaps {
            status = .partial
        } else {
            status = .available
        }
        let output = HealthHistoryToolOutput(
            status: status,
            startDate: formatter.string(from: startDay),
            endDate: formatter.string(from: endDay),
            days: dailySummaries,
            message: Self.message(for: status)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    private static func validateRange(start: Date, end: Date, calendar: Calendar) throws {
        guard start <= end else { throw GetHealthHistoryToolError.invalidRange }
        guard end <= calendar.startOfDay(for: Date()) else { throw HealthHistoryQueryError.futureDate }
        let dayCount = calendar.dateComponents([.day], from: start, to: end).day ?? Int.max
        guard (0..<HealthHistoryQueryError.maximumDays).contains(dayCount) else {
            throw HealthHistoryQueryError.rangeTooLarge
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private static func message(for status: HealthHistoryToolStatus) -> String {
        switch status {
        case .available:
            "每日状态基于当日记录和此前个人基线，仅用于健康管理参考。"
        case .partial:
            "部分日期或领域证据不足；缺失项不会按零处理。"
        case .noData:
            "所选时段没有可用健康记录；缺失不代表零。"
        }
    }
}

private enum HealthHistoryToolStatus: String, Encodable {
    case available
    case partial
    case noData
}

private struct HealthHistoryToolOutput: Encodable {
    let status: HealthHistoryToolStatus
    let startDate: String
    let endDate: String
    let days: [HealthHistoryDayOutput]
    let message: String
}

private struct HealthHistoryDayOutput: Encodable {
    let date: String
    let domainStatuses: [String: String]
    /// Values are keyed by evidence metric so their units remain unambiguous.
    let observations: [String: Double]
    let recoveryStatus: String
    let trainingLoadBand: String
}

private enum GetHealthHistoryToolError: Error, LocalizedError {
    case invalidDates
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .invalidDates:
            "日期缺失或格式无效，请使用 ISO8601。"
        case .invalidRange:
            "开始日期必须早于或等于结束日期。"
        }
    }
}
