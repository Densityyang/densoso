import Foundation
import SwiftData

enum DensosoSchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(8, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV5.models + [
            HealthKitSampleIndexRecord.self,
            DensosoSchemaV7.ConversationToolSchemaVersionRecord.self,
        ]
    }

    /// Stores lookup metadata for rebuilding daily caches after a sample moves or is deleted.
    @Model final class HealthKitSampleIndexRecord {
        @Attribute(.unique) var sampleID: UUID
        var stream: String
        var dayKey: String
        var startDate: Date
        var endDate: Date
        var needsRequery: Bool
        /// Stable JSON array of unresolved projection day keys; mirrors `needsRequery`.
        var pendingDayKeysJSON: String
        /// Retains the historical store column while avoiding PersistentModel.isDeleted.
        @Attribute(originalName: "isDeleted") var isTombstoned: Bool

        init(
            sampleID: UUID,
            stream: String,
            dayKey: String,
            startDate: Date,
            endDate: Date,
            needsRequery: Bool = false,
            pendingDayKeys: [String]? = nil,
            isTombstoned: Bool = false
        ) {
            self.sampleID = sampleID
            self.stream = stream
            self.dayKey = dayKey
            self.startDate = startDate
            self.endDate = endDate
            let sortedPendingDayKeys = Array(Set(pendingDayKeys ?? (needsRequery ? [dayKey] : []))).sorted()
            self.pendingDayKeysJSON = Self.encodePendingDayKeys(sortedPendingDayKeys)
            self.needsRequery = needsRequery || !sortedPendingDayKeys.isEmpty
            self.isTombstoned = isTombstoned
        }

        private static func encodePendingDayKeys(_ keys: [String]) -> String {
            let sortedKeys = Array(Set(keys)).sorted()
            guard let data = try? JSONEncoder().encode(sortedKeys),
                  let value = String(data: data, encoding: .utf8) else {
                return "[]"
            }
            return value
        }
    }
}
