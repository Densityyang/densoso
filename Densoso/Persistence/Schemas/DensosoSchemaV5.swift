import Foundation
import SwiftData

enum DensosoSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(5, 0, 0) }

    // Existing V4 model types are unchanged. Reuse them so V4 entity identities
    // remain stable, and add only the request ledger introduced in V5.
    static var models: [any PersistentModel.Type] {
        DensosoSchemaV4.models + [AgentRequestRecord.self]
    }

    @Model final class AgentRequestRecord {
        @Attribute(.unique) var requestID: UUID
        var conversationID: UUID
        var startedAt: Date
        var absoluteDeadline: Date
        var maximumProviderRounds: Int
        var maximumToolCalls: Int
        var providerRoundsUsed: Int
        var toolCallsUsed: Int
        var inputTokens: Int
        var cachedInputTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
        var resumeCount: Int
        var stateRaw: String
        var updatedAt: Date

        init(
            requestID: UUID,
            conversationID: UUID,
            startedAt: Date,
            absoluteDeadline: Date,
            maximumProviderRounds: Int,
            maximumToolCalls: Int,
            providerRoundsUsed: Int = 0,
            toolCallsUsed: Int = 0,
            inputTokens: Int = 0,
            cachedInputTokens: Int = 0,
            outputTokens: Int = 0,
            reasoningTokens: Int = 0,
            resumeCount: Int = 0,
            stateRaw: String = "running",
            updatedAt: Date? = nil
        ) {
            self.requestID = requestID
            self.conversationID = conversationID
            self.startedAt = startedAt
            self.absoluteDeadline = absoluteDeadline
            self.maximumProviderRounds = maximumProviderRounds
            self.maximumToolCalls = maximumToolCalls
            self.providerRoundsUsed = providerRoundsUsed
            self.toolCallsUsed = toolCallsUsed
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.resumeCount = resumeCount
            self.stateRaw = stateRaw
            self.updatedAt = updatedAt ?? startedAt
        }
    }
}
