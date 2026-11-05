import DensosoDomain
import Foundation

typealias TodayHealthStateProvider = @Sendable (Date) async throws -> HealthNarrativeContext?

@MainActor
struct GetTodayHealthStateTool: AgentTool {
    private let stateProvider: TodayHealthStateProvider

    init(stateProvider: @escaping TodayHealthStateProvider = { _ in nil }) {
        self.stateProvider = stateProvider
    }

    var definition: ToolSchema {
        .strictObject(
            name: "get_today_health_state",
            description: "读取今天已有的健康状态、个人基线与证据引用；数据不足时明确返回不足，不把缺失数据当作零，也不提供医学诊断。",
            properties: [:],
            required: []
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        try await response(asOf: Date())
    }

    func response(asOf date: Date) async throws -> String {
        let context = try await stateProvider(date)
        return try response(asOf: date, context: context)
    }

    func response(asOf date: Date, state: HealthStateV2?) throws -> String {
        try response(asOf: date, cloudState: state.map(Self.cloudState), vitalTrends: [], activityTrends: [])
    }

    func response(asOf date: Date, context: HealthNarrativeContext?) throws -> String {
        let cloudState = context?.cloudHealthState
            ?? context?.healthState.map(Self.cloudState)
        try response(
            asOf: date,
            cloudState: cloudState,
            vitalTrends: context?.vitalTrends ?? [],
            activityTrends: context?.activityTrends ?? []
        )
    }

    private func response(
        asOf date: Date,
        cloudState: CloudHealthStateContext?,
        vitalTrends: [HealthVitalTrendContext],
        activityTrends: [HealthActivityTrendContext]
    ) throws -> String {
        let output = TodayHealthStateToolOutput(
            status: Self.status(for: cloudState, vitalTrends: vitalTrends, activityTrends: activityTrends),
            asOf: date,
            healthState: cloudState,
            vitalTrends: vitalTrends,
            activityTrends: activityTrends,
            evidenceReferences: Self.evidenceReferences(
                in: cloudState,
                vitalTrends: vitalTrends,
                activityTrends: activityTrends
            ),
            message: Self.message(for: cloudState, vitalTrends: vitalTrends, activityTrends: activityTrends)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        return String(decoding: data, as: UTF8.self)
    }

    private static func status(
        for state: CloudHealthStateContext?,
        vitalTrends: [HealthVitalTrendContext],
        activityTrends: [HealthActivityTrendContext]
    ) -> TodayHealthStateToolStatus {
        guard state != nil || !vitalTrends.isEmpty || !activityTrends.isEmpty else { return .unavailable }
        guard hasCurrentEvidence(state, vitalTrends: vitalTrends, activityTrends: activityTrends) else {
            return hasCoverageGaps(state, vitalTrends: vitalTrends, activityTrends: activityTrends)
                ? .insufficientEvidence
                : .noData
        }
        let hasIncompleteVital = vitalTrends.contains {
            $0.latestMedian != nil && ($0.dataCoverage != .complete || $0.status == .partial || $0.status == .unknown)
        }
        let hasIncompleteDomain = (state?.domains ?? []).contains {
            $0.currentValue != nil && ($0.status == .partial || $0.status == .unknown)
        }
        let hasIncompleteActivity = activityTrends.contains {
            $0.currentValue != nil && ($0.dataCoverage != .complete || $0.status == .partial || $0.status == .unknown)
        }
        let hasIncompleteTrainingLoad = state?.trainingLoad.map { $0.dataCoverage != .complete } ?? false
        return hasIncompleteVital || hasIncompleteDomain || hasIncompleteActivity || hasIncompleteTrainingLoad
            ? .insufficientEvidence
            : .available
    }

    private static func evidenceReferences(
        in state: CloudHealthStateContext?,
        vitalTrends: [HealthVitalTrendContext],
        activityTrends: [HealthActivityTrendContext]
    ) -> [EvidenceReference] {
        let references = (state?.domains ?? []).flatMap { domain in
            domain.evidenceKeys.map { EvidenceReference(key: $0, source: domain.domain.rawValue) }
        } + (state?.recovery?.evidence ?? []) + (state?.tomorrowGuidance?.reasons ?? [])
            + vitalTrends.compactMap { trend in
                guard trend.latestMedian != nil, let evidenceKey = trend.evidenceKey else { return nil }
                return EvidenceReference(key: evidenceKey, source: trend.metric.rawValue)
            }
            + activityTrends.compactMap { trend in
                guard trend.currentValue != nil,
                      let evidenceKey = trend.evidenceKey,
                      evidenceKey == trend.metric.evidenceKey else { return nil }
                return EvidenceReference(key: evidenceKey, source: HealthDomain.activity.rawValue)
            }
        var seen = Set<String>()
        return references.filter { seen.insert("\($0.source):\($0.key)").inserted }
    }

    private static func message(
        for state: CloudHealthStateContext?,
        vitalTrends: [HealthVitalTrendContext],
        activityTrends: [HealthActivityTrendContext]
    ) -> String? {
        guard state != nil || !vitalTrends.isEmpty || !activityTrends.isEmpty else {
            return "今天的健康状态暂时不可用。"
        }
        if !hasCurrentEvidence(state, vitalTrends: vitalTrends, activityTrends: activityTrends) {
            if hasCoverageGaps(state, vitalTrends: vitalTrends, activityTrends: activityTrends) {
                return "部分已授权数据覆盖未知或不完整；数据空缺不代表零。"
            }
            return "目前没有记录到今天的健康数据；数据空缺不代表零。"
        }
        let hasPartialCurrentData = vitalTrends.contains {
            $0.latestMedian != nil && ($0.dataCoverage != .complete || $0.status == .partial || $0.status == .unknown)
        } || (state?.domains ?? []).contains {
            $0.currentValue != nil && ($0.status == .partial || $0.status == .unknown)
        } || activityTrends.contains {
            $0.currentValue != nil && ($0.dataCoverage != .complete || $0.status == .partial || $0.status == .unknown)
        } || (state?.trainingLoad.map { $0.dataCoverage != .complete } ?? false)

        if hasPartialCurrentData {
            return "部分已授权数据覆盖不完整；数据空缺不代表零。"
        }
        return nil
    }

    private static func hasCurrentEvidence(
        _ state: CloudHealthStateContext?,
        vitalTrends: [HealthVitalTrendContext],
        activityTrends: [HealthActivityTrendContext]
    ) -> Bool {
        (state?.domains ?? []).contains { $0.currentValue != nil }
            || vitalTrends.contains { $0.latestMedian != nil }
            || activityTrends.contains { $0.currentValue != nil }
            || state?.trainingLoad?.ratio != nil
    }

    private static func hasCoverageGaps(
        _ state: CloudHealthStateContext?,
        vitalTrends: [HealthVitalTrendContext],
        activityTrends: [HealthActivityTrendContext]
    ) -> Bool {
        vitalTrends.contains { $0.dataCoverage != .complete }
            || activityTrends.contains { $0.dataCoverage != .complete }
            || (state?.domains ?? []).contains { $0.status == .unknown || $0.status == .partial }
            || state?.trainingLoad?.dataCoverage == .unknown
            || state?.trainingLoad?.dataCoverage == .partial
    }

    private static func cloudState(_ state: HealthStateV2) -> CloudHealthStateContext {
        CloudHealthStateContext(
            domains: state.domains,
            recovery: state.recovery,
            trainingLoad: HealthTrainingLoadContext(summary: state.trainingLoad),
            tomorrowGuidance: state.tomorrowGuidance
        )
    }
}

private enum TodayHealthStateToolStatus: String, Encodable {
    case available
    case insufficientEvidence
    case noData
    case unavailable
}

private struct TodayHealthStateToolOutput: Encodable {
    let status: TodayHealthStateToolStatus
    let asOf: Date
    let healthState: CloudHealthStateContext?
    let vitalTrends: [HealthVitalTrendContext]
    let activityTrends: [HealthActivityTrendContext]
    let evidenceReferences: [EvidenceReference]
    let message: String?
}
