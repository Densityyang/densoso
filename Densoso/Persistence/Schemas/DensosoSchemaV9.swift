import Foundation
import SwiftData

enum DensosoSchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(9, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV8.models + [AgentRequestCostBudgetRecord.self]
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
