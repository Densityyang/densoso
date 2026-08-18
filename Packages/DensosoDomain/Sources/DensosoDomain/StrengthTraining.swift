import Foundation

public enum ExerciseCatalogVersion {
    /// Pinned free-exercise-db revision included in this app release.
    public static let current = "free-exercise-db-b0eed061e1c8"
}

/// App-owned strength data. HealthKit remains the authority for the workout
/// session itself, while these details are linked after HealthKit returns its UUID.
public struct StrengthSetLog: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let exerciseID: String
    public let exerciseName: String
    public let repetitions: Int
    public let loadKilograms: Double?
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        exerciseID: String,
        exerciseName: String,
        repetitions: Int,
        loadKilograms: Double? = nil,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.exerciseName = exerciseName
        self.repetitions = repetitions
        self.loadKilograms = loadKilograms
        self.completedAt = completedAt
    }
}

/// The final HealthKit UUID is the only cross-device identity used to attach
/// app-domain strength sets to a saved workout.
public struct StrengthWorkoutSummary: Codable, Equatable, Sendable {
    public let healthKitUUID: UUID
    public let logicalSessionID: UUID?
    public let catalogVersion: String
    public let completedSets: [StrengthSetLog]

    public init(
        healthKitUUID: UUID,
        logicalSessionID: UUID?,
        catalogVersion: String,
        completedSets: [StrengthSetLog]
    ) {
        self.healthKitUUID = healthKitUUID
        self.logicalSessionID = logicalSessionID
        self.catalogVersion = catalogVersion
        self.completedSets = completedSets
    }
}

public struct RestTimer: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case running(endsAt: Date)
        case finished
    }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func start(duration: TimeInterval, now: Date = Date()) {
        state = .running(endsAt: now.addingTimeInterval(max(0, duration)))
    }

    @discardableResult
    public mutating func refresh(now: Date = Date()) -> Bool {
        guard case .running(let endsAt) = state, now >= endsAt else { return false }
        state = .finished
        return true
    }

    public func secondsRemaining(now: Date = Date()) -> Int {
        guard case .running(let endsAt) = state else { return 0 }
        return max(0, Int(ceil(endsAt.timeIntervalSince(now))))
    }

    public mutating func cancel() {
        state = .idle
    }
}
