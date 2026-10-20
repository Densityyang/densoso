import DensosoDomain
import Foundation

@MainActor
struct GetPendingActionsTool: AgentTool {
    private static let maximumReturnedActions = 20
    private static let maximumSummaryLength = 240
    private static let maximumOutputCharacters = 7_500

    var definition: ToolSchema {
        .strictObject(
            name: "get_pending_actions",
            description: "读取尚待用户确认的操作摘要。此工具只查看状态，不确认、不拒绝，也不提交操作。",
            properties: [:],
            required: []
        )
    }

    func execute(
        argumentsJSON: String,
        context: AgentSession,
        clientRequestID: UUID
    ) async throws -> String {
        try response(actions: context.pendingActions, asOf: Date())
    }

    func response(actions: [PendingAction], asOf date: Date) throws -> String {
        let candidates = actions
            .filter { !$0.state.isTerminal && $0.expiresAt > date }
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    if lhs.state == .committing { return true }
                    if rhs.state == .committing { return false }
                }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var summaries = Array(candidates.prefix(Self.maximumReturnedActions)).map { action in
            PendingActionSummary(
                actionID: action.id.uuidString.lowercased(),
                type: action.payload.actionType.rawValue,
                title: action.payload.title,
                summary: String(action.payload.summary.prefix(Self.maximumSummaryLength)),
                state: action.state.rawValue,
                createdAt: action.createdAt,
                expiresAt: action.expiresAt
            )
        }
        var hasMore = candidates.count > summaries.count
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let output = PendingActionsToolOutput(
                status: summaries.isEmpty ? "noActions" : "available",
                count: summaries.count,
                hasMore: hasMore,
                actions: summaries
            )
            let serialized = String(decoding: try encoder.encode(output), as: UTF8.self)
            if serialized.count <= Self.maximumOutputCharacters || summaries.isEmpty {
                return serialized
            }
            summaries.removeLast()
            hasMore = true
        }
    }
}

private struct PendingActionsToolOutput: Encodable {
    let status: String
    let count: Int
    let hasMore: Bool
    let actions: [PendingActionSummary]
}

private struct PendingActionSummary: Encodable {
    let actionID: String
    let type: String
    let title: String
    let summary: String
    let state: String
    let createdAt: Date
    let expiresAt: Date
}
