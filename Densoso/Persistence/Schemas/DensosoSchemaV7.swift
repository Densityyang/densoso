import Foundation
import SwiftData

enum DensosoSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(7, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV6.models + [ConversationToolSchemaVersionRecord.self]
    }

    /// Per-conversation tool contract metadata. Older stores have no row and
    /// are lazily classified as schema v1 when they next resume.
    @Model final class ConversationToolSchemaVersionRecord {
        @Attribute(.unique) var conversationID: UUID
        var toolSchemaVersion: Int
        var createdAt: Date
        var updatedAt: Date

        init(
            conversationID: UUID,
            toolSchemaVersion: Int,
            createdAt: Date = Date(),
            updatedAt: Date? = nil
        ) {
            self.conversationID = conversationID
            self.toolSchemaVersion = toolSchemaVersion
            self.createdAt = createdAt
            self.updatedAt = updatedAt ?? createdAt
        }
    }
}
