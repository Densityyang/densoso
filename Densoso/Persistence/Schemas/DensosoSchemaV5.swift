import Foundation
import SwiftData

enum DensosoSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(5, 0, 0) }

    // Existing V4 model types are unchanged. Reuse them so V4 entity identities
    // remain stable, while V5 adds request, check-in, and confirmed preference records.
    static var models: [any PersistentModel.Type] {
        DensosoSchemaV4.models + [
            AgentRequestRecord.self,
            DailyCheckInRecord.self,
            UserPreferenceRecord.self,
        ]
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
        /// A non-content marker; media bytes and extracted evidence never enter the request ledger.
        var containsTransientImage: Bool = false
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
            containsTransientImage: Bool = false,
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
            self.containsTransientImage = containsTransientImage
            self.stateRaw = stateRaw
            self.updatedAt = updatedAt ?? startedAt
        }
    }

    /// Persisted only after explicit confirmation. This model is user-reported data,
    /// separate from HealthKit samples and objective health projections.
    @Model final class DailyCheckInRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var sourceActionKey: String
        var occurredAt: Date
        var energyRaw: String
        var stressRaw: String
        var subjectiveSleepRaw: String
        var note: String?
        var sourceRaw: String
        var createdAt: Date

        init(
            id: UUID = UUID(),
            sourceActionKey: String,
            occurredAt: Date,
            energyRaw: String,
            stressRaw: String,
            subjectiveSleepRaw: String,
            note: String? = nil,
            sourceRaw: String = "userReported",
            createdAt: Date = Date()
        ) {
            self.id = id
            self.sourceActionKey = sourceActionKey
            self.occurredAt = occurredAt
            self.energyRaw = energyRaw
            self.stressRaw = stressRaw
            self.subjectiveSleepRaw = subjectiveSleepRaw
            self.note = note
            self.sourceRaw = sourceRaw
            self.createdAt = createdAt
        }
    }

    /// Persisted only after explicit confirmation of a user-reported preference.
    /// These records are separate from HealthKit facts and are not provider context.
    @Model final class UserPreferenceRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var sourceActionKey: String
        var categoryRaw: String
        var statement: String
        var sourceRaw: String
        var createdAt: Date

        init(
            id: UUID = UUID(),
            sourceActionKey: String,
            categoryRaw: String,
            statement: String,
            sourceRaw: String = "userReported",
            createdAt: Date = Date()
        ) {
            self.id = id
            self.sourceActionKey = sourceActionKey
            self.categoryRaw = categoryRaw
            self.statement = statement
            self.sourceRaw = sourceRaw
            self.createdAt = createdAt
        }
    }
}
