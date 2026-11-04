import Foundation
import SwiftData

enum DensosoSchemaV13: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(13, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV12.models + [ToolExecutionJournalRecord.self]
    }

    /// Durable execution checkpoint for Agent tool invocations that can stage actions.
    @Model final class ToolExecutionJournalRecord {
        @Attribute(.unique) var invocationID: String
        var requestID: UUID
        var conversationID: UUID
        var logicalRound: Int
        var callIndex: Int
        var toolCallID: String
        var toolName: String
        var argumentsHash: String
        var requestTimeAnchor: Date
        var stateRaw: String
        var preparedPayloadData: Data?
        var pendingActionID: UUID?
        var resultData: Data?
        var createdAt: Date
        var updatedAt: Date
        var completedAt: Date?

        init(_ entry: ToolExecutionJournalEntry) {
            invocationID = entry.invocationID
            requestID = entry.requestID
            conversationID = entry.conversationID
            logicalRound = entry.logicalRound
            callIndex = entry.callIndex
            toolCallID = entry.toolCallID
            toolName = entry.toolName
            argumentsHash = entry.argumentsHash
            requestTimeAnchor = entry.requestTimeAnchor
            stateRaw = entry.state.rawValue
            preparedPayloadData = entry.preparedPayloadData
            pendingActionID = entry.pendingActionID
            resultData = entry.resultData
            createdAt = entry.createdAt
            updatedAt = entry.updatedAt
            completedAt = entry.completedAt
        }

        func entry() throws -> ToolExecutionJournalEntry {
            guard let state = ToolExecutionJournalState(rawValue: stateRaw) else {
                throw ToolExecutionJournalError.invocationIdentityMismatch
            }
            return ToolExecutionJournalEntry(
                invocationID: invocationID,
                requestID: requestID,
                conversationID: conversationID,
                logicalRound: logicalRound,
                callIndex: callIndex,
                toolCallID: toolCallID,
                toolName: toolName,
                argumentsHash: argumentsHash,
                requestTimeAnchor: requestTimeAnchor,
                state: state,
                preparedPayloadData: preparedPayloadData,
                pendingActionID: pendingActionID,
                resultData: resultData,
                createdAt: createdAt,
                updatedAt: updatedAt,
                completedAt: completedAt
            )
        }
    }
}
