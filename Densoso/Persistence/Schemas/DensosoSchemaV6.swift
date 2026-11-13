import Foundation
import SwiftData

enum DensosoSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(6, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV5.models + [HealthKitSampleIndexRecord.self]
    }

    /// Stores only identifier and temporal lookup metadata needed to rebuild
    /// daily caches when a sample moves or HealthKit reports a deletion.
    @Model final class HealthKitSampleIndexRecord {
        @Attribute(.unique) var sampleID: UUID
        var stream: String
        var dayKey: String
        var startDate: Date
        var endDate: Date
        var needsRequery: Bool
        /// Stable JSON array of unresolved projection day keys; mirrors `needsRequery`.
        var pendingDayKeysJSON: String
        /// A deleted sample stays indexed until every unresolved day has been rebuilt.
        var isDeleted: Bool

        init(
            sampleID: UUID,
            stream: String,
            dayKey: String,
            startDate: Date,
            endDate: Date,
            needsRequery: Bool = false,
            pendingDayKeys: [String]? = nil,
            isDeleted: Bool = false
        ) {
            self.sampleID = sampleID
            self.stream = stream
            self.dayKey = dayKey
            self.startDate = startDate
            self.endDate = endDate
            let sortedPendingDayKeys = Array(Set(pendingDayKeys ?? (needsRequery ? [dayKey] : []))).sorted()
            self.pendingDayKeysJSON = Self.encodePendingDayKeys(sortedPendingDayKeys)
            self.needsRequery = needsRequery || !sortedPendingDayKeys.isEmpty
            self.isDeleted = isDeleted
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
