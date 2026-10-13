import Foundation

public struct HouseholdPortionPrior: Codable, Equatable, Sendable {
    public let unit: String
    public let p10Grams: Double
    public let p50Grams: Double
    public let p90Grams: Double
    public let version: String

    public init(unit: String, p10Grams: Double, p50Grams: Double, p90Grams: Double, version: String) {
        self.unit = unit
        self.p10Grams = p10Grams
        self.p50Grams = p50Grams
        self.p90Grams = p90Grams
        self.version = version
    }
}

public enum PortionEvidence: Codable, Equatable, Sendable {
    case userCorrection(low: Double, likely: Double, high: Double)
    case kitchenScale(grams: Double)
    case exactGrams(grams: Double)
    case approximateGrams(grams: Double)
    case packageServing(gramsPerServing: Double, count: Double)
    case household(prior: HouseholdPortionPrior, count: Double)
    case photo(likelyGrams: Double, hasScale: Bool, isMixedDish: Bool, isOccluded: Bool, unknownContainer: Bool)
}

public protocol PortionEstimating: Sendable {
    func estimate(evidence: [PortionEvidence], food: FoodCandidate?) throws -> PortionEstimate
}

public struct PortionEstimator: PortionEstimating, Sendable {
    public init() {}

    public func estimate(
        evidence: [PortionEvidence],
        food: FoodCandidate? = nil
    ) throws -> PortionEstimate {
        let candidates = try evidence.map(Self.candidate).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.label < $1.label
        }
        guard var selected = candidates.first else {
            throw MealEvidenceError.missingPortionEvidence
        }

        var conflicts: [String] = []
        for candidate in candidates.dropFirst() {
            let low = max(selected.low, candidate.low)
            let high = min(selected.high, candidate.high)
            if low <= high {
                if candidate.priority == selected.priority {
                    selected.low = low
                    selected.high = high
                    selected.likely = min(max(selected.likely, low), high)
                }
            } else {
                conflicts.append("\(selected.label)|\(candidate.label)")
            }
        }

        return try PortionEstimate(
            lowGrams: selected.low,
            likelyGrams: selected.likely,
            highGrams: selected.high,
            isMeasured: selected.isMeasured,
            source: selected.source,
            conflicts: conflicts
        )
    }

    private struct Candidate {
        var low: Double
        var likely: Double
        var high: Double
        let priority: Int
        let isMeasured: Bool
        let source: PortionEstimate.Source
        let label: String
    }

    private static func candidate(_ evidence: PortionEvidence) throws -> Candidate {
        func requirePositive(_ value: Double) throws -> Double {
            guard value.isFinite, value > 0 else { throw MealEvidenceError.invalidPortionRange }
            return value
        }

        switch evidence {
        case .userCorrection(let low, let likely, let high):
            _ = try PortionEstimate(
                lowGrams: low,
                likelyGrams: likely,
                highGrams: high,
                isMeasured: false,
                source: .userCorrection
            )
            return Candidate(
                low: low, likely: likely, high: high, priority: 100,
                isMeasured: false, source: .userCorrection, label: "userCorrection"
            )
        case .kitchenScale(let grams):
            let grams = try requirePositive(grams)
            return Candidate(
                low: grams, likely: grams, high: grams, priority: 90,
                isMeasured: true, source: .measured, label: "measured"
            )
        case .exactGrams(let grams):
            let grams = try requirePositive(grams)
            return Candidate(
                low: grams, likely: grams, high: grams, priority: 85,
                isMeasured: false, source: .userReportedExact, label: "userReportedExact"
            )
        case .approximateGrams(let grams):
            let grams = try requirePositive(grams)
            return Candidate(
                low: grams * 0.9, likely: grams, high: grams * 1.1, priority: 80,
                isMeasured: false, source: .approximateGrams, label: "approximate"
            )
        case .packageServing(let gramsPerServing, let count):
            let total = try requirePositive(gramsPerServing) * requirePositive(count)
            return Candidate(
                low: total * 0.95, likely: total, high: total * 1.05, priority: 70,
                isMeasured: false, source: .packageServing, label: "package"
            )
        case .household(let prior, let count):
            let count = try requirePositive(count)
            guard prior.p10Grams > 0,
                  prior.p10Grams <= prior.p50Grams,
                  prior.p50Grams <= prior.p90Grams else {
                throw MealEvidenceError.invalidPortionRange
            }
            return Candidate(
                low: prior.p10Grams * count,
                likely: prior.p50Grams * count,
                high: prior.p90Grams * count,
                priority: 60,
                isMeasured: false,
                source: .householdPrior,
                label: "household:\(prior.version):\(prior.unit)"
            )
        case .photo(let likelyGrams, let hasScale, let isMixedDish, let isOccluded, let unknownContainer):
            let likely = try requirePositive(likelyGrams)
            let minimumHalfWidth: Double
            if isMixedDish || isOccluded || unknownContainer { minimumHalfWidth = 0.65 }
            else if hasScale { minimumHalfWidth = 0.30 }
            else { minimumHalfWidth = 0.50 }
            return Candidate(
                low: max(0, likely * (1 - minimumHalfWidth)),
                likely: likely,
                high: likely * (1 + minimumHalfWidth),
                priority: hasScale ? 50 : 40,
                isMeasured: false,
                source: hasScale ? .photoWithScale : .photoWithoutScale,
                label: "photo"
            )
        }
    }
}
