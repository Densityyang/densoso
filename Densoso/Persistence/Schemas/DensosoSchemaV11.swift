import Foundation
import SwiftData

enum DensosoSchemaV11: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(11, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV10.models + [CloudHealthContextPolicyRecord.self]
    }

    /// Provider-scoped policy snapshots keep consent state, revision, and hash
    /// separate from individual text/image/audio consent records.
    @Model final class CloudHealthContextPolicyRecord {
        @Attribute(.unique) var policyKey: String
        var schemaVersion: Int
        var policyID: UUID
        var providerRaw: String
        var revision: Int
        var stateRaw: String
        var allowedClassesRaw: String
        var createdAt: Date
        var updatedAt: Date
        var confirmedAt: Date?
        var policyHash: String
        var changeSourceRaw: String

        init(
            policyKey: String,
            schemaVersion: Int,
            policyID: UUID,
            providerRaw: String,
            revision: Int,
            stateRaw: String,
            allowedClassesRaw: String,
            createdAt: Date,
            updatedAt: Date,
            confirmedAt: Date?,
            policyHash: String,
            changeSourceRaw: String
        ) {
            self.policyKey = policyKey
            self.schemaVersion = max(schemaVersion, 1)
            self.policyID = policyID
            self.providerRaw = providerRaw
            self.revision = max(revision, 0)
            self.stateRaw = stateRaw
            self.allowedClassesRaw = allowedClassesRaw
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.confirmedAt = confirmedAt
            self.policyHash = policyHash
            self.changeSourceRaw = changeSourceRaw
        }
    }
}
