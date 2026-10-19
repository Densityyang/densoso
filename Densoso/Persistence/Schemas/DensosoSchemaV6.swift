import Foundation
import SwiftData

enum DensosoSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(6, 0, 0) }

    static var models: [any PersistentModel.Type] {
        DensosoSchemaV5.models + [HealthKitSampleIndexRecord.self]
    }

    /// Stores only the identifier-to-day lookup needed to rebuild a daily cache
    /// after HealthKit reports that an object was deleted.
    @Model final class HealthKitSampleIndexRecord {
        @Attribute(.unique) var sampleID: UUID
        var stream: String
        var dayKey: String
        var startDate: Date
        var endDate: Date
        var needsRequery: Bool

        init(
            sampleID: UUID,
            stream: String,
            dayKey: String,
            startDate: Date,
            endDate: Date,
            needsRequery: Bool = false
        ) {
            self.sampleID = sampleID
            self.stream = stream
            self.dayKey = dayKey
            self.startDate = startDate
            self.endDate = endDate
            self.needsRequery = needsRequery
        }
    }
}
