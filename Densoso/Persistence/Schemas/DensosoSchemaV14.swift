import Foundation
import SwiftData

enum DensosoSchemaV14: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(14, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV13.models + [MealPriorContributionRecord.self]
    }

    /// One reversible, meal-owned contribution to an automatically learned prior.
    /// User-managed priors stay on their existing record and do not use this ledger.
    @Model final class MealPriorContributionRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var contributionKey: String
        var sourceActionKey: String?
        var priorKey: String
        var kindRaw: String
        var payloadData: Data
        var observationWeight: Int
        var isLegacyAggregate: Bool
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            contributionKey: String,
            sourceActionKey: String?,
            priorKey: String,
            kindRaw: String,
            payloadData: Data,
            observationWeight: Int = 1,
            isLegacyAggregate: Bool = false,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.contributionKey = contributionKey
            self.sourceActionKey = sourceActionKey
            self.priorKey = priorKey
            self.kindRaw = kindRaw
            self.payloadData = payloadData
            self.observationWeight = max(1, observationWeight)
            self.isLegacyAggregate = isLegacyAggregate
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
