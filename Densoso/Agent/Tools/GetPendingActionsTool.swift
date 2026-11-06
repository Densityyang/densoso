import DensosoDomain
import Foundation

@MainActor
struct GetPendingActionsTool: AgentTool {
    private static let maximumReturnedActions = 20
    private static let maximumOutputUTF8Bytes = 60_000

    var definition: ToolSchema {
        .strictObject(
            name: "get_pending_actions",
            description: "仅读取当前请求授权类别内的待确认操作内容、来源和状态。noAuthorizedActions 表示没有可提供给当前请求的授权草案，不代表本机没有其他待确认操作。结果过多时按 nextOffset 继续读取；此工具只查看状态，不确认、不拒绝，也不提交操作。",
            properties: [
                "offset": .integer(minimum: 0, maximum: 10_000, description: "继续读取时使用上次返回的 nextOffset；默认 0"),
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
            throw GetPendingActionsToolError.invalidArguments
        }
        let offset = arguments["offset"] as? Int ?? 0
        return try response(
            actions: context.pendingActions,
            asOf: Date(),
            offset: offset,
            allowedClasses: context.cloudHealthContextPolicyForPendingActions()?.allowedClasses ?? []
        )
    }

    func response(
        actions: [PendingAction],
        asOf date: Date,
        offset: Int = 0,
        allowedClasses: Set<ProviderDataClass> = []
    ) throws -> String {
        guard (0...10_000).contains(offset) else { throw GetPendingActionsToolError.invalidOffset }
        let candidates = actions
            .filter {
                !$0.state.isTerminal
                    && $0.expiresAt > date
                    && PendingActionConsentPolicy.dataClass(for: $0.payload)
                        .map { allowedClasses.contains($0) } == true
            }
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    if lhs.state == .committing { return true }
                    if rhs.state == .committing { return false }
                }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var summaries = Array(candidates.dropFirst(offset).prefix(Self.maximumReturnedActions)).map { action in
            PendingActionSummary(
                actionID: action.id.uuidString.lowercased(),
                type: action.payload.actionType.rawValue,
                title: action.payload.title,
                summary: action.payload.summary,
                state: action.state.rawValue,
                createdAt: action.createdAt,
                expiresAt: action.expiresAt,
                confidence: action.payload.confidence,
                payload: action.payload
            )
        }
        var oversizedActions: [OversizedPendingActionReference] = []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let consumedCount = summaries.count + oversizedActions.count
            let hasMore = offset + consumedCount < candidates.count
            let output = PendingActionsToolOutput(
                status: summaries.isEmpty
                    ? (oversizedActions.isEmpty ? "noAuthorizedActions" : "requiresLocalReview")
                    : "available",
                count: summaries.count,
                hasMore: hasMore,
                nextOffset: hasMore ? offset + consumedCount : nil,
                actions: summaries,
                oversizedActions: oversizedActions
            )
            let serialized = String(decoding: try encoder.encode(output), as: UTF8.self)
            if serialized.utf8.count <= Self.maximumOutputUTF8Bytes || summaries.isEmpty {
                return serialized
            }
            let removed = summaries.removeLast()
            if summaries.isEmpty {
                oversizedActions.append(
                    OversizedPendingActionReference(
                        actionID: removed.actionID,
                        type: removed.type,
                        consentDataClass: PendingActionConsentPolicy.dataClass(for: removed.payload)?.rawValue,
                        preferenceCategory: preferenceCategory(for: removed.payload),
                        createdAt: removed.createdAt,
                        expiresAt: removed.expiresAt,
                        title: String(removed.title.prefix(80)),
                        summary: String(removed.summary.prefix(160)),
                        state: removed.state,
                        payloadUTF8Bytes: try encoder.encode(removed.payload).count,
                        requiresLocalReview: true
                    )
                )
            }
        }
    }

    private func preferenceCategory(for payload: ActionPayload) -> String? {
        guard case .userPreference(let preference) = payload else { return nil }
        return preference.category.rawValue
    }
}

private struct PendingActionsToolOutput: Encodable {
    let status: String
    let count: Int
    let hasMore: Bool
    let nextOffset: Int?
    let actions: [PendingActionSummary]
    let oversizedActions: [OversizedPendingActionReference]
}

private struct OversizedPendingActionReference: Encodable {
    let actionID: String
    let type: String
    let consentDataClass: String?
    let preferenceCategory: String?
    let createdAt: Date
    let expiresAt: Date
    let title: String
    let summary: String
    let state: String
    let payloadUTF8Bytes: Int
    let requiresLocalReview: Bool
}

private struct PendingActionSummary: Encodable {
    let actionID: String
    let type: String
    let title: String
    let summary: String
    let state: String
    let createdAt: Date
    let expiresAt: Date
    let confidence: Double
    let payload: ActionPayload
}

private enum GetPendingActionsToolError: Error {
    case invalidArguments
    case invalidOffset
}
