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

        let stableEncoder = JSONEncoder()
        stableEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var latestSummaryByDay: [Date: (timestamp: Date, summary: HealthHistoryDayOutput, tieBreakKey: String)] = [:]
        for point in points {
            let pointDay = calendar.startOfDay(for: point.date)
            guard pointDay >= startDay && pointDay <= endDay else { continue }

            let orderedDomains = point.state.domains.sorted {
                Self.domainOrderKey($0) < Self.domainOrderKey($1)
            }
            var domainStatuses: [String: String] = [:]
            var observations: [String: Double] = [:]
            for domain in orderedDomains {
                let domainKey = domain.domain.rawValue
                guard domainStatuses[domainKey] == nil else { continue }
                domainStatuses[domainKey] = domain.status.rawValue
                guard let value = domain.currentValue,
                      let evidenceKey = domain.evidenceKeys.first,
                      value.isFinite,
                      observations[evidenceKey] == nil else { continue }
                observations[evidenceKey] = value
            }
            if point.state.trainingLoad.dataCoverage == .complete,
               let ratio = point.state.trainingLoad.ratio,
               ratio.isFinite {
                observations["trainingLoad.ratio"] = ratio
            }
            let loadCoverage = point.state.trainingLoad.dataCoverage
            let summary = HealthHistoryDayOutput(
                date: formatter.string(from: pointDay),
                domainStatuses: domainStatuses,
                observations: observations,
                recoveryStatus: point.state.recovery.status.rawValue,
                trainingLoadCoverage: loadCoverage.rawValue,
                trainingLoadBand: loadCoverage == .complete ? point.state.trainingLoad.band.rawValue : nil
            )
            let tieBreakKey = String(decoding: try stableEncoder.encode(summary), as: UTF8.self)
            if let current = latestSummaryByDay[pointDay] {
                if point.date > current.timestamp
                    || (point.date == current.timestamp && tieBreakKey < current.tieBreakKey) {
                    latestSummaryByDay[pointDay] = (point.date, summary, tieBreakKey)
                }
            } else {
                latestSummaryByDay[pointDay] = (point.date, summary, tieBreakKey)
            }
        }
        let dailySummaries = latestSummaryByDay.keys.sorted().compactMap {
            latestSummaryByDay[$0]?.summary
        }

        let hasObservations = dailySummaries.contains { !$0.observations.isEmpty }
        let hasGaps = dailySummaries.contains { summary in
            summary.domainStatuses.values.contains("noData")
                || summary.domainStatuses.values.contains(HealthDomainStatus.unknown.rawValue)
                || summary.domainStatuses.values.contains(HealthDomainStatus.partial.rawValue)
                || summary.domainStatuses.values.contains("learning")
                || summary.recoveryStatus == RecoveryStatus.insufficientEvidence.rawValue
                || summary.trainingLoadCoverage != HealthDataCoverage.complete.rawValue
        }
        let status: HealthHistoryToolStatus
        if !hasObservations {
            status = hasGaps ? .partial : .noData
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

    private static func domainOrderKey(_ result: HealthDomainResult) -> String {
        let evidenceKeys = result.evidenceKeys
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        let currentValue = result.currentValue.map { String($0.bitPattern, radix: 16) } ?? "nil"
        return [result.domain.rawValue, result.status.rawValue, evidenceKeys, currentValue]
            .joined(separator: "\u{1f}")
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
    let trainingLoadCoverage: String
    let trainingLoadBand: String?
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
