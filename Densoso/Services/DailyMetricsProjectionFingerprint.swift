import DensosoDomain
import Foundation
import SwiftData

struct DailyMetricsProjectionFingerprintContext: Equatable, Sendable {
    let sourceRecordRevisions: [String]
    let profileRevision: String?
    let goalRevision: String?
    let algorithmVersion: String

    init(
        sourceRecordRevisions: [String] = [],
        profileRevision: String? = nil,
        goalRevision: String? = nil,
        algorithmVersion: String = AlgorithmVersions.dailyMetricsProjection
    ) {
        self.sourceRecordRevisions = sourceRecordRevisions.sorted()
        self.profileRevision = profileRevision
        self.goalRevision = goalRevision
        self.algorithmVersion = algorithmVersion
    }

    var canonicalComponents: [String] {
        [
            "algorithm:\(algorithmVersion)",
            "profile-revision:\(profileRevision ?? "none")",
            "goal-revision:\(goalRevision ?? "none")",
        ] + sourceRecordRevisions.map { "source-revision:\($0)" }
    }
}

enum DailyMetricsProjectionFingerprint {
    static func context(
        on date: Date,
        asOf referenceDate: Date? = nil,
        inputs: DailyMetricsProjectionInputs,
        profileRevision: ProfileRevisionRecord?,
        weightObservations: [WeightObservation],
        in modelContext: ModelContext
    ) throws -> DailyMetricsProjectionFingerprintContext {
        let day = Calendar.current.startOfDay(for: date)
        let effectiveAt = referenceDate ?? day
        let profileKey = profileRevision?.profileKey ?? "primary"
        let goalPredicate = #Predicate<GoalProfileRecord> { $0.profileKey == profileKey }
        let goal = try modelContext.fetch(FetchDescriptor<GoalProfileRecord>(predicate: goalPredicate))
            .filter { $0.effectiveFrom <= effectiveAt }
            .sorted {
                if $0.effectiveFrom != $1.effectiveFrom { return $0.effectiveFrom > $1.effectiveFrom }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            .first

        // HealthKit cursor anchors record query progress, not the values consumed by
        // DailyMetrics. The canonical daily snapshot values are fingerprinted by
        // CaloricEngine; advancing a cursor without changing that snapshot must not
        // invalidate the projection.
        let weightRevisions = weightObservations.map {
            "weight:\($0.id.uuidString.lowercased()):\($0.measuredAt.timeIntervalSince1970):\($0.kilograms):\($0.source.rawValue):\($0.healthKitSyncIdentifier ?? "none")"
        }
        let profileToken = profileRevision.map {
            "\($0.id.uuidString.lowercased()):\($0.profileKey):\($0.effectiveFrom.timeIntervalSince1970):\($0.createdAt.timeIntervalSince1970)"
        }
        let goalToken = goal.map {
            "\($0.id.uuidString.lowercased()):\($0.profileKey):\($0.effectiveFrom.timeIntervalSince1970):\($0.updatedAt.timeIntervalSince1970):target-weight:\($0.targetWeightKilograms ?? -1):daily-deficit:\($0.dailyDeficitKcal ?? -1):daily-protein:\($0.dailyProteinGrams ?? -1)"
        }

        return DailyMetricsProjectionFingerprintContext(
            sourceRecordRevisions: inputs.sourceRecordRevisions + weightRevisions,
            profileRevision: profileToken,
            goalRevision: goalToken,
            algorithmVersion: AlgorithmVersions.dailyMetricsProjection
        )
    }

    static func isCurrent(
        storedFingerprint: String,
        storedAlgorithmVersion: String,
        requiresRecompute: Bool,
        expectedFingerprint: String,
        expectedAlgorithmVersion: String
    ) -> Bool {
        !requiresRecompute
            && sourceMatches(
                storedFingerprint: storedFingerprint,
                storedAlgorithmVersion: storedAlgorithmVersion,
                expectedFingerprint: expectedFingerprint,
                expectedAlgorithmVersion: expectedAlgorithmVersion
            )
    }

    static func sourceMatches(
        storedFingerprint: String,
        storedAlgorithmVersion: String,
        expectedFingerprint: String,
        expectedAlgorithmVersion: String
    ) -> Bool {
        !storedFingerprint.isEmpty
            && storedAlgorithmVersion == expectedAlgorithmVersion
            && storedFingerprint == expectedFingerprint
    }
}
