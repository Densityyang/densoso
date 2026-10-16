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
        if let basal = validEnergy(observedBasalEnergyKcal),
           let active = validEnergy(observedActiveEnergyKcal) {
            return try? EnergyEstimate(
                low: basal + active,
                likely: basal + active,
                high: basal + active,
                confidence: .high,
                source: .observed
            )
        }

        guard let profile,
              let age = profile.age,
              age >= 0,
              let weight = effectiveWeightKg,
              weight.isFinite,
              weight > 0,
              profile.heightCm.isFinite,
              profile.heightCm > 0,
              let basal = basalMetabolicRate(
                sex: profile.biologicalSex,
                weightKg: weight,
                heightCm: profile.heightCm,
                age: age
              )
        else {
            return nil
        }

        guard let activityFactor = activityFactor(for: profile.activityLevel) else { return nil }
        let likely = basal * activityFactor
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

    private static func validEnergy(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
