import Foundation

public enum WorkoutEnergySource: String, Codable, Sendable, Equatable {
    case measured
    case userEntered
    case metEstimate
}

public struct WorkoutEnergyInput: Codable, Sendable, Equatable {
    public let measuredKilocalories: Double?
    public let userEnteredKilocalories: Double?
    public let metEstimatedKilocalories: Double?

    public init(
        measuredKilocalories: Double? = nil,
        userEnteredKilocalories: Double? = nil,
        metEstimatedKilocalories: Double? = nil
    ) {
        self.measuredKilocalories = measuredKilocalories
        self.userEnteredKilocalories = userEnteredKilocalories
        self.metEstimatedKilocalories = metEstimatedKilocalories
    }
}

public struct ResolvedWorkoutEnergy: Codable, Sendable, Equatable {
    public let kilocalories: Double
    public let source: WorkoutEnergySource

    public init(kilocalories: Double, source: WorkoutEnergySource) {
        self.kilocalories = kilocalories
        self.source = source
    }
}

/// Selects exactly one active-energy source. Measured HealthKit energy wins over
/// a user correction, which wins over a MET estimate. Non-finite and negative
/// values are discarded rather than silently double-counted.
public struct WorkoutEnergyResolver: Sendable {
    public init() {}

    public func resolve(_ input: WorkoutEnergyInput) -> ResolvedWorkoutEnergy? {
        if let value = valid(input.measuredKilocalories) {
            return ResolvedWorkoutEnergy(kilocalories: value, source: .measured)
        }
        if let value = valid(input.userEnteredKilocalories) {
            return ResolvedWorkoutEnergy(kilocalories: value, source: .userEntered)
        }
        if let value = valid(input.metEstimatedKilocalories) {
            return ResolvedWorkoutEnergy(kilocalories: value, source: .metEstimate)
        }
        return nil
    }

    private func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
