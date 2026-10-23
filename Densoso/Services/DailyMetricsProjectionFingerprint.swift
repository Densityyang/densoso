import CryptoKit
import DensosoDomain
import Foundation
import SwiftData

struct DailyMetricsProjectionFingerprintContext: Equatable, Sendable {
    let sourceRecordRevisions: [String]
    let healthKitCursorRevisions: [String]
    let profileRevision: String?
    let goalRevision: String?
    let algorithmVersion: String

    init(
        sourceRecordRevisions: [String] = [],
        healthKitCursorRevisions: [String] = [],
        profileRevision: String? = nil,
        goalRevision: String? = nil,
        algorithmVersion: String = AlgorithmVersions.dailyMetricsProjection
    ) {
        self.sourceRecordRevisions = sourceRecordRevisions.sorted()
        self.healthKitCursorRevisions = healthKitCursorRevisions.sorted()
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
            + healthKitCursorRevisions.map { "healthkit-cursor:\($0)" }
    }
}

enum DailyMetricsProjectionFingerprint {
    private static let dailyMetricsCursorStreams: Set<String> = [
        HealthMetricID.activeEnergy.rawValue,
        HealthMetricID.restingEnergy.rawValue,
        HealthMetricID.stepCount.rawValue,
        HealthMetricID.exerciseMinutes.rawValue,
    ]

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

        let cursors = try modelContext.fetch(FetchDescriptor<HealthKitImportCursor>())
            .filter { cursor in
                guard dailyMetricsCursorStreams.contains(cursor.stream) else { return false }
                guard let lastSuccessfulAt = cursor.lastSuccessfulAt,
                      day <= lastSuccessfulAt else { return false }
                if let lookbackStart = cursor.lookbackStart {
                    return lookbackStart <= day
                }
                return false
            }
            .sorted { $0.stream < $1.stream }
            .map { cursor in
                let anchorDigest = cursor.anchorData.map(digest) ?? "none"
                return [
                    cursor.stream,
                    "lookback:\(cursor.lookbackStart?.timeIntervalSince1970 ?? -1)",
                    "anchor:\(anchorDigest)",
                ].joined(separator: ":")
            }

        // HealthKit energy/steps/exercise values are fingerprinted by CaloricEngine's
        // canonical inputs. Hashing the entire daily cache would include derived
        // intake/weight mirrors written after the metric projection transaction.
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
            healthKitCursorRevisions: cursors,
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

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func dayKey(for day: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
