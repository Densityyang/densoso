import Foundation
import SwiftData

enum DensosoSchemaV15: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(15, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV14.models + [ConfirmedPlanSessionIndexRecord.self]
    }

    /// Synchronized query rows for confirmed plans. Per-session dates make
    /// Daily Loop reads proportional to the requested window rather than the
    /// lifetime size of the schedule history.
    @Model final class ConfirmedPlanSessionIndexRecord {
        @Attribute(.unique) var id: UUID
        var actionID: UUID
        var sessionID: UUID
        var scheduledAt: Date
        var planKindRaw: String
        var stateRaw: String
        var notes: String

        init(
            id: UUID = UUID(),
            actionID: UUID,
            sessionID: UUID,
            scheduledAt: Date,
            planKindRaw: String,
            stateRaw: String,
            notes: String
        ) {
            self.id = id
            self.actionID = actionID
            self.sessionID = sessionID
            self.scheduledAt = scheduledAt
            self.planKindRaw = planKindRaw
            self.stateRaw = stateRaw
            self.notes = notes
        }
    }
}
