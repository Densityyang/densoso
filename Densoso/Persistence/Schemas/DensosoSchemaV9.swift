import Foundation
import SwiftData

enum DensosoSchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(9, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV8.models.filter {
            ObjectIdentifier($0) != ObjectIdentifier(DensosoSchemaV4.ProviderUsageRecord.self)
        } + [
            ProviderUsageRecord.self,
            AgentRequestCostBudgetRecord.self,
        ]
    }

    /// V9 retains the usage rows while adding request identity and bounded
    /// measurement fields. Legacy rows keep nil/zero unknown defaults.
    @Model final class ProviderUsageRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var usageKey: String
        var provider: String
        var model: String
        var capability: String
        var requestID: UUID?
        var attempt: Int = 0
        var inputTokens: Int
        var cachedInputTokens: Int = 0
        var outputTokens: Int
        var reasoningTokens: Int = 0
        var imageCount: Int = 0
        var audioSeconds: Double
        var latencyMilliseconds: Int?
        var estimatedCostMicros: Int64
        var currency: String
        var rateVersion: String
        var createdAt: Date

        init(
            id: UUID = UUID(),
            usageKey: String,
            provider: String,
            model: String,
            capability: String,
            requestID: UUID? = nil,
            attempt: Int = 0,
            inputTokens: Int = 0,
            cachedInputTokens: Int = 0,
            outputTokens: Int = 0,
            reasoningTokens: Int = 0,
            imageCount: Int = 0,
            audioSeconds: Double = 0,
            latencyMilliseconds: Int? = nil,
            estimatedCostMicros: Int64 = 0,
            currency: String = "USD",
            rateVersion: String = "unknown",
            createdAt: Date = Date()
        ) {
            self.id = id
            self.usageKey = usageKey
            self.provider = provider
            self.model = model
            self.capability = capability
            self.requestID = requestID
            self.attempt = max(attempt, 0)
            self.inputTokens = max(inputTokens, 0)
            self.cachedInputTokens = max(cachedInputTokens, 0)
            self.outputTokens = max(outputTokens, 0)
            self.reasoningTokens = max(reasoningTokens, 0)
            self.imageCount = max(imageCount, 0)
            self.audioSeconds = audioSeconds.isFinite ? max(audioSeconds, 0) : 0
            self.latencyMilliseconds = latencyMilliseconds.map { max($0, 0) }
            self.estimatedCostMicros = estimatedCostMicros
            self.currency = currency
            self.rateVersion = rateVersion
            self.createdAt = createdAt
        }
    }

    /// Stores the request's conservative cost reservations separately so V5's
    /// durable request ledger remains byte-for-byte compatible.
    @Model final class AgentRequestCostBudgetRecord {
        @Attribute(.unique) var requestID: UUID
        var conversationID: UUID
        var maximumCostMicros: Int64
        /// Conservative per-round reservations; this is not an invoice total.
        var reservedCostMicros: Int64
        var currency: String
        var providerRaw: String
        var model: String
        var pricingVersion: String
        var costStateRaw: String
        var lastReservedProviderRound: Int
        var lastReservedCostMicros: Int64
        var updatedAt: Date

        init(
            requestID: UUID,
            conversationID: UUID,
            maximumCostMicros: Int64,
            reservedCostMicros: Int64 = 0,
            currency: String = "unresolved",
            providerRaw: String = "unresolved",
            model: String = "unresolved",
            pricingVersion: String = "unavailable",
            costStateRaw: String = "unresolved",
            lastReservedProviderRound: Int = 0,
            lastReservedCostMicros: Int64 = 0,
            updatedAt: Date = Date()
        ) {
            self.requestID = requestID
            self.conversationID = conversationID
            self.maximumCostMicros = max(maximumCostMicros, 0)
            self.reservedCostMicros = max(reservedCostMicros, 0)
            self.currency = currency
            self.providerRaw = providerRaw
            self.model = model
            self.pricingVersion = pricingVersion
            self.costStateRaw = costStateRaw
            self.lastReservedProviderRound = max(lastReservedProviderRound, 0)
            self.lastReservedCostMicros = max(lastReservedCostMicros, 0)
            self.updatedAt = updatedAt
        }
    }
}
