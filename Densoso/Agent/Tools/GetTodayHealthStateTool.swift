import DensosoDomain
import Foundation

typealias TodayHealthStateProvider = @Sendable (Date) async throws -> HealthStateV2?

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
        let state = try await stateProvider(date)
        return try response(asOf: date, state: state)
    }

    func response(asOf date: Date, state: HealthStateV2?) throws -> String {
        let output = TodayHealthStateToolOutput(
            status: Self.status(for: state),
            asOf: date,
            healthState: state,
            evidenceReferences: Self.evidenceReferences(in: state),
            message: Self.message(for: state)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(output)
        return String(decoding: data, as: UTF8.self)
    }

    private static func status(for state: HealthStateV2?) -> TodayHealthStateToolStatus {
        guard let state, !state.domains.isEmpty else { return .unavailable }
        if hasNoEvidence(state) { return .noData }
        if state.recovery.status == .insufficientEvidence { return .insufficientEvidence }
        return .available
    }

    private static func evidenceReferences(in state: HealthStateV2?) -> [EvidenceReference] {
        guard let state else { return [] }
        let references = state.domains.flatMap { domain in
            domain.evidenceKeys.map { EvidenceReference(key: $0, source: domain.domain.rawValue) }
        } + state.recovery.evidence + (state.tomorrowGuidance?.reasons ?? [])
        var seen = Set<String>()
        return references.filter { seen.insert("\($0.source):\($0.key)").inserted }
    }

    private static func message(for state: HealthStateV2?) -> String? {
        guard let state, !state.domains.isEmpty else {
            return "今天的健康状态暂时不可用。"
        }
        if hasNoEvidence(state) {
            return "目前没有记录到今天的健康数据；数据空缺不代表零。"
        }
        if state.recovery.status == .insufficientEvidence {
            return "目前证据不足以可靠判断恢复状态；我不会据此猜测。"
        }
        return nil
    }

    private static func hasNoEvidence(_ state: HealthStateV2) -> Bool {
        state.domains.allSatisfy({ $0.status == .noData })
            && state.trainingLoad.band == .unavailable
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
    let healthState: HealthStateV2?
    let evidenceReferences: [EvidenceReference]
    let message: String?
}
