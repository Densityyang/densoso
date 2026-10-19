import DensosoDomain
import Foundation
import SwiftData

enum LocalWeightObservationReader {
    private static let batchSize = 128

    static func latestObservation(
        in modelContext: ModelContext,
        effectiveAt date: Date
    ) throws -> WeightObservation? {
        let minimumConfidence = WeightTimeline.defaultMinimumConfidence
        let predicate = #Predicate<WeightRecord> {
            $0.measuredAt <= date && $0.confidence >= minimumConfidence
        }
        var descriptor = FetchDescriptor<WeightRecord>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\WeightRecord.measuredAt, order: .reverse),
                SortDescriptor(\WeightRecord.id, order: .reverse),
            ]
        )
        descriptor.fetchLimit = batchSize

        var offset = 0
        while true {
            descriptor.fetchOffset = offset
            let records = try modelContext.fetch(descriptor)
            guard !records.isEmpty else { return nil }
            for record in records {
                guard let source = WeightSource(rawValue: record.source) else { continue }
                let observation = WeightObservation(
                    id: record.id,
                    measuredAt: record.measuredAt,
                    kilograms: record.kilograms,
                    source: source,
                    confidence: record.confidence,
                    healthKitSyncIdentifier: record.healthKitSyncIdentifier
                )
                guard observation.isValid,
                      observation.confidence >= minimumConfidence else { continue }
                return observation
            }

            offset += records.count
            if records.count < batchSize { return nil }
        }
    }
}
