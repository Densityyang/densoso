import Foundation

/// Identifies the authoritative source of a persisted workout record.
public enum WorkoutOrigin: String, Codable, Sendable, Equatable {
    case watchHealthKit
    case externalHealthKit
    case userEntered
    case metEstimated
}

public enum WorkoutDataQuality: String, Codable, Sendable, Equatable {
    case complete
    case partial
    case unavailable
}

/// Routes can arrive after their parent workout, so their state is modeled independently.
public enum WorkoutRouteStatus: String, Codable, Sendable, Equatable {
    case pending
    case available
    case unavailable
}

public enum WorkoutSnapshotError: Error, Sendable, Equatable {
    case invalidDuration
}

/// A HealthKit-independent representation used at the persistence boundary.
/// `healthKitUUID` is the canonical idempotency key after HealthKit saves a workout.
public struct WorkoutSnapshot: Codable, Sendable, Equatable {
    public let healthKitUUID: UUID
    public let logicalSessionID: UUID?
    public let startedAt: Date
    public let duration: TimeInterval
    public let activityType: String
    public let energyInput: WorkoutEnergyInput
    public let origin: WorkoutOrigin
    public let sourceBundleIdentifier: String?
    public let sourceVersion: String?
    public let sourceRevision: String?
    public let deviceName: String?
    public let deviceModel: String?
    public let dataQuality: WorkoutDataQuality
    public let routeStatus: WorkoutRouteStatus

    public init(
        healthKitUUID: UUID,
        logicalSessionID: UUID? = nil,
        startedAt: Date,
        duration: TimeInterval,
        activityType: String,
        energyInput: WorkoutEnergyInput,
        origin: WorkoutOrigin,
        sourceBundleIdentifier: String? = nil,
        sourceVersion: String? = nil,
        sourceRevision: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        dataQuality: WorkoutDataQuality,
        routeStatus: WorkoutRouteStatus = .pending
    ) throws {
        guard duration.isFinite, duration >= 0 else {
            throw WorkoutSnapshotError.invalidDuration
        }
        self.healthKitUUID = healthKitUUID
        self.logicalSessionID = logicalSessionID
        self.startedAt = startedAt
        self.duration = duration
        self.activityType = activityType
        self.energyInput = energyInput
        self.origin = origin
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceVersion = sourceVersion
        self.sourceRevision = sourceRevision
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.dataQuality = dataQuality
        self.routeStatus = routeStatus
    }

    public var resolvedEnergy: ResolvedWorkoutEnergy? {
        WorkoutEnergyResolver().resolve(energyInput)
    }
}
