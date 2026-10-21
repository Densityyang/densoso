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
            $0.stream == stream && $0.isTombstoned == false && $0.endDate <= date
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

            let batchDayKeys = Array(Set(indexes.map(\.dayKey)).subtracting(inspectedDayKeys)).sorted()
            var snapshotsByDayKey: [String: DailyHealthSnapshotRecord] = [:]
            if !batchDayKeys.isEmpty {
                let snapshotPredicate = #Predicate<DailyHealthSnapshotRecord> {
                    batchDayKeys.contains($0.dayKey)
                }
                let snapshotRecords = try modelContext.fetch(
                    FetchDescriptor<DailyHealthSnapshotRecord>(predicate: snapshotPredicate)
                )
                for record in snapshotRecords {
                    snapshotsByDayKey[record.dayKey] = record
                }
            }
            var visitedBatchDays = Set<String>()
            for index in indexes {
                guard !inspectedDayKeys.contains(index.dayKey),
                      visitedBatchDays.insert(index.dayKey).inserted,
                      let snapshotRecord = snapshotsByDayKey[index.dayKey],
                      let snapshot = try? decoder.decode(DailyHealthSnapshot.self, from: snapshotRecord.payloadData) else {
                    continue
                }
                if let readState = snapshot.healthReadStates?[stream], readState != .available { continue }
                guard let aggregate = snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass),
                      let sampleID = aggregate.latestSampleID,
                      let measuredAt = aggregate.latestSampleAt,
                      measuredAt <= date,
                      let kilograms = aggregate.latestValue,
                      kilograms.isFinite, kilograms > 0 else { continue }
                return WeightObservation(
                    id: sampleID,
                    measuredAt: measuredAt,
                    kilograms: kilograms,
                    source: .healthKit,
                    confidence: 1
                )
            }
            inspectedDayKeys.formUnion(batchDayKeys)

            offset += indexes.count
            if indexes.count < batchSize { return nil }
        }
    }
}
