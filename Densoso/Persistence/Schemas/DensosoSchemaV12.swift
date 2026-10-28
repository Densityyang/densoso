import Foundation
import SwiftData

enum DensosoSchemaV12: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(12, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV11.models + [PersonalMealDishPriorRecord.self]
    }

    /// Aggregates only confirmed or explicitly user-managed dish templates.
    @Model final class PersonalMealDishPriorRecord {
        @Attribute(.unique) var id: UUID
        @Attribute(.unique) var priorKey: String
        var dishKey: String
        var dishName: String
        var cookingMethodKey: String
        var cookingMethod: String?
        var ingredientsJSON: String
        var observationCount: Int
        var isUserManaged: Bool
        var sourceActionKey: String?
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            priorKey: String,
            dishKey: String,
            dishName: String,
            cookingMethodKey: String,
            cookingMethod: String?,
            ingredientsJSON: String,
            observationCount: Int,
            isUserManaged: Bool,
            sourceActionKey: String?,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.priorKey = priorKey
            self.dishKey = dishKey
            self.dishName = dishName
            self.cookingMethodKey = cookingMethodKey
            self.cookingMethod = cookingMethod
            self.ingredientsJSON = ingredientsJSON
            self.observationCount = max(observationCount, 0)
            self.isUserManaged = isUserManaged
            self.sourceActionKey = sourceActionKey
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}
