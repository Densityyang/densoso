import DensosoDomain
import Foundation
import SwiftData

enum HealthKitWeightObservationReader {
    private static let batchSize = 128

    static func latestObservation(
        in modelContext: ModelContext,
        effectiveAt date: Date
    ) throws -> WeightObservation? {
        let stream = HealthMetricID.bodyMass.rawValue
        let predicate = #Predicate<HealthKitSampleIndexRecord> {
            $0.stream == stream && $0.isDeleted == false && $0.endDate <= date
        }
        var descriptor = FetchDescriptor<HealthKitSampleIndexRecord>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\HealthKitSampleIndexRecord.endDate, order: .reverse),
                SortDescriptor(\HealthKitSampleIndexRecord.sampleID, order: .reverse),
            ]
        )
        descriptor.fetchLimit = batchSize

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var inspectedDayKeys = Set<String>()
        var offset = 0
        while true {
            descriptor.fetchOffset = offset
            let indexes = try modelContext.fetch(descriptor)
            guard !indexes.isEmpty else { return nil }

            for index in indexes where inspectedDayKeys.insert(index.dayKey).inserted {
                let targetDayKey = index.dayKey
                let snapshotPredicate = #Predicate<DailyHealthSnapshotRecord> {
                    $0.dayKey == targetDayKey
                }
                var snapshotDescriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: snapshotPredicate)
                snapshotDescriptor.fetchLimit = 1
                guard let snapshotRecord = try modelContext.fetch(snapshotDescriptor).first,
                      let snapshot = try? decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData) else {
                    continue
                }
                if let readState = snapshot.healthReadStates?[stream], readState != .available {
                    continue
                }
                guard let aggregate = snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass),
                      let sampleID = aggregate.latestSampleID,
                      let measuredAt = aggregate.latestSampleAt,
                      measuredAt <= date,
                      let kilograms = aggregate.latestValue,
                      kilograms.isFinite, kilograms > 0 else {
                    continue
                }
                return WeightObservation(
                    id: sampleID,
                    measuredAt: measuredAt,
                    kilograms: kilograms,
                    source: .healthKit,
                    confidence: 1
                )
            }

            offset += indexes.count
            if indexes.count < batchSize { return nil }
        }
    }
}
