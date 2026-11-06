import Foundation

public enum EstimateConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public enum EnergySource: String, Codable, Sendable {
    case observed
    case estimated
}

public struct EnergyEstimate: Codable, Equatable, Sendable {
    public let low: Double
    public let likely: Double
    public let high: Double
    public let confidence: EstimateConfidence
    public let source: EnergySource

    public init(
        low: Double,
        likely: Double,
        high: Double,
        confidence: EstimateConfidence,
        source: EnergySource
    ) throws {
        let range = try EstimateRange(low: low, likely: likely, high: high)
        self.low = range.low
        self.likely = range.likely
        self.high = range.high
        self.confidence = confidence
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case low
        case likely
        case high
        case confidence
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                low: container.decode(Double.self, forKey: .low),
                likely: container.decode(Double.self, forKey: .likely),
                high: container.decode(Double.self, forKey: .high),
                confidence: container.decode(EstimateConfidence.self, forKey: .confidence),
                source: container.decode(EnergySource.self, forKey: .source)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .low,
                in: container,
                debugDescription: "Energy estimate values must be finite, non-negative, and ordered."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(low, forKey: .low)
        try container.encode(likely, forKey: .likely)
        try container.encode(high, forKey: .high)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(source, forKey: .source)
    }
}

public struct EnergyAccountingResult: Equatable, Sendable {
    public let expenditure: EnergyEstimate?
    public let basalComponent: EnergyEstimate?
    public let activeComponent: EnergyEstimate?

    public init(
        expenditure: EnergyEstimate?,
        basalComponent: EnergyEstimate?,
        activeComponent: EnergyEstimate?
    ) {
        self.expenditure = expenditure
        self.basalComponent = basalComponent
        self.activeComponent = activeComponent
    }
}

/// Canonical daily expenditure rules. Workout records are intentionally absent:
/// HealthKit active energy already includes workout activity.
public enum EnergyAccounting {
    /// A fallback range around the activity-prior estimate; it remains visibly estimated.
    public static let fallbackRelativeUncertainty = 0.15

    public static func expenditure(
        observedBasalEnergyKcal: Double?,
        observedActiveEnergyKcal: Double?,
        profile: EffectiveProfile?,
        effectiveWeightKg: Double?
    ) -> EnergyEstimate? {
        calculate(
            observedBasalEnergyKcal: observedBasalEnergyKcal,
            observedActiveEnergyKcal: observedActiveEnergyKcal,
            profile: profile,
            effectiveWeightKg: effectiveWeightKg
        ).expenditure
    }

    /// Uses each observed HealthKit component once and estimates only the
    /// missing component. An observed active value is never added to a full
    /// activity-factor TDEE prior.
    public static func calculate(
        observedBasalEnergyKcal: Double?,
        observedActiveEnergyKcal: Double?,
        profile: EffectiveProfile?,
        effectiveWeightKg: Double?
    ) -> EnergyAccountingResult {
        let observedBasal = validEnergy(observedBasalEnergyKcal).flatMap(observedComponent)
        let observedActive = validEnergy(observedActiveEnergyKcal).flatMap(observedComponent)
        let basal = observedBasal ?? estimatedBasal(profile: profile, weightKg: effectiveWeightKg)
        let active = observedActive ?? estimatedActive(basal: basal, activityLevel: profile?.activityLevel)
        guard let basal, let active else {
            return EnergyAccountingResult(
                expenditure: nil,
                basalComponent: basal,
                activeComponent: active
            )
        }

        let bothObserved = basal.source == .observed && active.source == .observed
        guard let expenditure = try? EnergyEstimate(
            low: basal.low + active.low,
            likely: basal.likely + active.likely,
            high: basal.high + active.high,
            confidence: bothObserved ? .high : .low,
            source: bothObserved ? .observed : .estimated
        ) else {
            return EnergyAccountingResult(
                expenditure: nil,
                basalComponent: basal,
                activeComponent: active
            )
        }
        return EnergyAccountingResult(
            expenditure: expenditure,
            basalComponent: basal,
            activeComponent: active
        )
    }

    public static func basalMetabolicRate(
        sex: BiologicalSex,
        weightKg: Double,
        heightCm: Double,
        age: Int
    ) -> Double? {
        guard weightKg.isFinite, weightKg > 0,
              heightCm.isFinite, heightCm > 0,
              age >= 0
        else {
            return nil
        }

        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
        let result: Double
        switch sex {
        case .male:
            result = base + 5
        case .female:
            result = base - 161
        case .other, .unspecified:
            return nil
        }
        return result.isFinite && result > 0 ? result : nil
    }

    private static func activityFactor(for level: ActivityLevel) -> Double? {
        switch level {
        case .unspecified: nil
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        case .veryActive: 1.9
        }
    }

    private static func observedComponent(_ value: Double) -> EnergyEstimate? {
        try? EnergyEstimate(
            low: value,
            likely: value,
            high: value,
            confidence: .high,
            source: .observed
        )
    }

    private static func estimatedBasal(profile: EffectiveProfile?, weightKg: Double?) -> EnergyEstimate? {
        guard let profile,
              let age = profile.age,
              age >= 0,
              let weightKg,
              weightKg.isFinite,
              weightKg > 0,
              profile.heightCm.isFinite,
              profile.heightCm > 0,
              let likely = basalMetabolicRate(
                sex: profile.biologicalSex,
                weightKg: weightKg,
                heightCm: profile.heightCm,
                age: age
              ) else { return nil }
        return estimatedComponent(likely)
    }

    private static func estimatedActive(
        basal: EnergyEstimate?,
        activityLevel: ActivityLevel?
    ) -> EnergyEstimate? {
        guard let basal,
              let activityLevel,
              let factor = activityFactor(for: activityLevel) else { return nil }
        let likely = basal.likely * (factor - 1)
        guard likely.isFinite, likely > 0 else { return nil }
        return estimatedComponent(likely)
    }

    private static func estimatedComponent(_ likely: Double) -> EnergyEstimate? {
        guard likely.isFinite, likely > 0 else { return nil }
        let margin = likely * fallbackRelativeUncertainty
        return try? EnergyEstimate(
            low: max(likely - margin, 0),
            likely: likely,
            high: likely + margin,
            confidence: .low,
            source: .estimated
        )
    }

    private static func validEnergy(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
