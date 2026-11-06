import Foundation
import SwiftData

enum DensosoSchemaV10: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(10, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV9.models + [PersonalMealPortionPriorRecord.self]
    }

    /// A personal unit-to-grams estimate learned only from an explicit user
    /// correction after the matching meal confirmation commits.
    @Model final class PersonalMealPortionPriorRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var priorKey: String
        var foodID: String?
        var foodName: String
        var unit: String
        var p10Grams: Double
        var p50Grams: Double
        var p90Grams: Double
        var sourceActionKey: String?
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            priorKey: String,
            foodID: String?,
            foodName: String,
            unit: String,
            p10Grams: Double,
            p50Grams: Double,
            p90Grams: Double,
            sourceActionKey: String? = nil,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.priorKey = priorKey
            self.foodID = foodID
            self.foodName = foodName
            self.unit = unit
            self.p10Grams = p10Grams
            self.p50Grams = p50Grams
            self.p90Grams = p90Grams
            self.sourceActionKey = sourceActionKey
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
