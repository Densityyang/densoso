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
    public static let algorithmVersion = "calorie-accounting-v2"

    public init() {}

    public func presentation(for estimate: EstimateRange) -> CaloriePresentation {
        let likelyKcal = Self.rounded(estimate.likely)
        let relativeWidth = (estimate.high - estimate.low) / max(estimate.likely, 1)
        if relativeWidth <= 0.35 {
            return .likely(kcal: likelyKcal, confidence: .high)
        }
        if relativeWidth <= 0.65 {
            return .likely(kcal: likelyKcal, confidence: .medium)
        }
        return .needsClarification(likelyKcal: likelyKcal)
    }

    private static func rounded(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), 0), 1_000_000_000))
    }
}
