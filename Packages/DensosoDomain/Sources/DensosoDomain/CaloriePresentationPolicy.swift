import Foundation

public enum CalorieConfidence: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low

    public var displayName: String {
        switch self {
        case .high: "高"
        case .medium: "中"
        case .low: "低"
        }
    }
}

public enum CaloriePresentation: Codable, Equatable, Sendable {
    case likely(kcal: Int, confidence: CalorieConfidence)
    case needsClarification(likelyKcal: Int)

    public var likelyKcal: Int {
        switch self {
        case .likely(let kcal, _): kcal
        case .needsClarification(let kcal): kcal
        }
    }

    public var confidence: CalorieConfidence {
        switch self {
        case .likely(_, let confidence): confidence
        case .needsClarification: .low
        }
    }
}

/// Presents the likely point estimate while reserving a single clarification
/// for unusually broad energy ranges.
public struct CaloriePresentationPolicy: Sendable {
    public static let algorithmVersion = AlgorithmVersions.calorieAccounting
    private static let likelyKcalStep = 25
    private static let maximumDisplayedKcal = 1_000_000_000

    public init() {}

    public func presentation(for estimate: EstimateRange) -> CaloriePresentation {
        let likelyKcal = Self.roundedLikelyKcal(estimate.likely)
        let relativeWidth = (estimate.high - estimate.low) / max(estimate.likely, 1)
        if relativeWidth <= 0.35 {
            return .likely(kcal: likelyKcal, confidence: .high)
        }
        if relativeWidth <= 0.65 {
            return .likely(kcal: likelyKcal, confidence: .medium)
        }
        return .needsClarification(likelyKcal: likelyKcal)
    }

    /// Uses a 25 kcal display step. A positive estimate below half a step still
    /// displays as one step so meal intake is never presented as zero.
    private static func roundedLikelyKcal(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let clampedValue = min(max(value, 0), Double(maximumDisplayedKcal))
        let step = Double(likelyKcalStep)
        let nearestStep = (clampedValue / step).rounded() * step
        let nonZeroDisplay = clampedValue > 0 ? max(step, nearestStep) : 0
        return Int(min(nonZeroDisplay, Double(maximumDisplayedKcal)))
    }
}
