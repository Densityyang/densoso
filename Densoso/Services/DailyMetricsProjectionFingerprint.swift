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
        algorithmVersion: String = AlgorithmVersions.calorieAccounting
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
    static func context(
        on date: Date,
        inputs: DailyMetricsProjectionInputs,
        profileRevision: ProfileRevisionRecord?,
        weightObservations: [WeightObservation],
        in modelContext: ModelContext
    ) throws -> DailyMetricsProjectionFingerprintContext {
        let day = Calendar.current.startOfDay(for: date)
        let profileKey = profileRevision?.profileKey ?? "primary"
        let goalPredicate = #Predicate<GoalProfileRecord> {
            $0.profileKey == profileKey && $0.effectiveFrom <= day
        }
        var goalDescriptor = FetchDescriptor<GoalProfileRecord>(
            predicate: goalPredicate,
            sortBy: [
                SortDescriptor(\GoalProfileRecord.effectiveFrom, order: .reverse),
                SortDescriptor(\GoalProfileRecord.updatedAt, order: .reverse),
                SortDescriptor(\GoalProfileRecord.id, order: .reverse),
            ]
        )
        goalDescriptor.fetchLimit = 1
        let goal = try modelContext.fetch(goalDescriptor).first

        let cursors = try modelContext.fetch(FetchDescriptor<HealthKitImportCursor>())
            .filter { cursor in
                guard let lastSuccessfulAt = cursor.lastSuccessfulAt,
                      day <= lastSuccessfulAt else { return false }
                if let lookbackStart = cursor.lookbackStart {
                    return lookbackStart <= day
                }
                return cursor.stream == "workouts"
                    && inputs.workouts.contains { $0.workoutOrigin == "healthKit" }
            }
            .sorted { $0.stream < $1.stream }
            .map { cursor in
                let anchorDigest = cursor.anchorData.map(digest) ?? "none"
                return [
                    cursor.stream,
                    "updated:\(cursor.updatedAt.timeIntervalSince1970)",
                    "successful:\(cursor.lastSuccessfulAt?.timeIntervalSince1970 ?? -1)",
                    "lookback:\(cursor.lookbackStart?.timeIntervalSince1970 ?? -1)",
                    "anchor:\(anchorDigest)",
                ].joined(separator: ":")
            }

        let dayKey = Self.dayKey(for: day)
        let snapshotPredicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == dayKey }
        var snapshotDescriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: snapshotPredicate)
        snapshotDescriptor.fetchLimit = 1
        let snapshot = try modelContext.fetch(snapshotDescriptor).first
        let snapshotRevision = snapshot.map {
            "daily-health-snapshot:\($0.dayKey):\($0.algorithmVersion):\($0.snapshotHash)"
        }
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
            sourceRecordRevisions: inputs.sourceRecordRevisions + weightRevisions + [snapshotRevision].compactMap { $0 },
            healthKitCursorRevisions: cursors,
            profileRevision: profileToken,
            goalRevision: goalToken,
            algorithmVersion: AlgorithmVersions.calorieAccounting
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
