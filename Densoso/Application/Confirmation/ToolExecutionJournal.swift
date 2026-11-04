import Foundation
import DensosoDomain

enum ToolExecutionJournalState: String, Codable, Sendable {
    case prepared
    case staged
    case completed
    case failed
    case interrupted
}

struct ToolExecutionJournalEntry: Equatable, Sendable {
    let invocationID: String
    let requestID: UUID
    let conversationID: UUID
    let logicalRound: Int
    let callIndex: Int
    let toolCallID: String
    let toolName: String
    let argumentsHash: String
    let requestTimeAnchor: Date
    var state: ToolExecutionJournalState
    var preparedPayloadData: Data?
    var pendingActionID: UUID?
    var resultData: Data?
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    var result: String? {
        resultData.flatMap { String(data: $0, encoding: .utf8) }
    }
}

enum ToolExecutionJournalError: Error, Equatable {
    case invocationIdentityMismatch
    case invalidStateTransition
}

enum ToolExecutionPayloadCodec {
    static func encode(_ payload: ActionPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> ActionPayload {
        try JSONDecoder().decode(ActionPayload.self, from: data)
    }
}
