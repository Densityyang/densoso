import Foundation

/// Quantity claims supplied by the model. These are hypotheses until a local
/// resolver validates them against user text or local package evidence.
public struct MealQuantityEvidence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case exactGrams
        case household
        case count
        case packageServing
        case photoEstimate
        case unknown
    }

    public let kind: Kind
    public let value: Double?
    public let unit: String?
    public let gramsPerServing: Double?

    public init(
        kind: Kind,
        value: Double? = nil,
        unit: String? = nil,
        gramsPerServing: Double? = nil
    ) {
        self.kind = kind
        self.value = value
        self.unit = unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gramsPerServing = gramsPerServing
    }
}

public enum MealQuantityEvidenceResolutionError: Error, Equatable, Sendable {
    case missingPortionEvidence
    case invalidQuantityEvidence
}

/// Converts model quantity hypotheses into conservative portion distributions.
/// Exact grams are accepted only through a separately validated user report.
public struct MealQuantityEvidenceResolver: Sendable {
    public static let algorithmVersion = "meal-quantity-evidence-v2"

    public init() {}

    public func resolve(
        _ evidence: MealQuantityEvidence,
        validatedUserReportedGrams: Double? = nil,
        validatedPackageGramsPerServing: Double? = nil,
        allowLowConfidenceModelEstimate: Bool = false
    ) throws -> PortionEvidence {
        if let validatedUserReportedGrams {
            let grams = try requirePositive(validatedUserReportedGrams)
            return .exactGrams(grams: grams)
        }

        switch evidence.kind {
        case .exactGrams:
            guard isGramUnit(evidence.unit) else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            let likelyGrams = try requirePositive(evidence.value)
            guard likelyGrams * 1.65 <= 5_000 else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            return .modelEstimate(likelyGrams: likelyGrams)

        case .household, .count:
            let count = try requirePositive(evidence.value)
            guard count <= 100,
                  let unit = normalizeUnit(evidence.unit),
                  let prior = prior(for: unit, kind: evidence.kind) else {
                throw MealQuantityEvidenceResolutionError.missingPortionEvidence
            }
            guard prior.p90Grams * count <= 5_000 else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            return .household(prior: prior, count: count)

        case .packageServing:
            guard isServingUnit(evidence.unit) else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            let servingCount = try requirePositive(evidence.value)
            guard servingCount <= 100 else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            guard let validatedPackageGramsPerServing else {
                if evidence.gramsPerServing != nil {
                    _ = try requirePositive(evidence.gramsPerServing)
                }
                throw MealQuantityEvidenceResolutionError.missingPortionEvidence
            }
            let localServingGrams = try requirePositive(validatedPackageGramsPerServing)
            guard localServingGrams * servingCount * 1.05 <= 5_000 else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            return .packageServing(
                gramsPerServing: localServingGrams,
                count: servingCount
            )

        case .photoEstimate:
            guard isGramUnit(evidence.unit) else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            let likelyGrams = try requirePositive(evidence.value)
            guard likelyGrams * 1.65 <= 5_000 else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            return .photo(
                likelyGrams: likelyGrams,
                hasScale: false,
                isMixedDish: true,
                isOccluded: true,
                unknownContainer: true
            )

        case .unknown:
            guard allowLowConfidenceModelEstimate else {
                throw MealQuantityEvidenceResolutionError.missingPortionEvidence
            }
            guard isGramUnit(evidence.unit) else {
                throw MealQuantityEvidenceResolutionError.missingPortionEvidence
            }
            let likelyGrams = try requirePositive(evidence.value)
            guard likelyGrams * 1.65 <= 5_000 else {
                throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
            }
            return .modelEstimate(likelyGrams: likelyGrams)
        }
    }

    private func requirePositive(_ value: Double?) throws -> Double {
        guard let value, value.isFinite, value > 0, value <= 5_000 else {
            throw MealQuantityEvidenceResolutionError.invalidQuantityEvidence
        }
        return value
    }

    private func isGramUnit(_ unit: String?) -> Bool {
        guard let unit = normalizeUnit(unit) else { return false }
        return ["g", "gram", "grams", "克", "公克"].contains(unit)
    }

    private func isServingUnit(_ unit: String?) -> Bool {
        guard let unit = normalizeUnit(unit) else { return false }
        return ["serving", "portion", "pack", "package", "份", "每份", "包"].contains(unit)
    }

    private func normalizeUnit(_ unit: String?) -> String? {
        guard let unit else { return nil }
        let normalized = unit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        return normalized.isEmpty ? nil : normalized
    }

    private func prior(
        for unit: String,
        kind: MealQuantityEvidence.Kind
    ) -> HouseholdPortionPrior? {
        let range: (Double, Double, Double)?
        switch (kind, unit) {
        case (.household, "bowl"), (.household, "碗"):
            range = (100, 160, 240)
        case (.household, "smallbowl"), (.household, "小碗"):
            range = (70, 120, 180)
        case (.household, "largebowl"), (.household, "大碗"):
            range = (150, 230, 340)
        case (.household, "fist"), (.household, "拳"), (.household, "拳头"):
            range = (90, 150, 220)
        case (.household, "palm"), (.household, "掌心"), (.household, "掌"):
            range = (70, 100, 145)
        case (.household, "cup"), (.household, "杯"):
            range = (180, 240, 320)
        case (.household, "slice"), (.household, "片"):
            range = (20, 30, 45)
        case (.count, "egg"), (.count, "鸡蛋"), (.count, "蛋"):
            range = (40, 52, 68)
        case (.count, "dumpling"), (.count, "饺子"):
            range = (14, 22, 32)
        case (.count, "slice"), (.count, "片"):
            range = (20, 30, 45)
        case (.count, "banana"), (.count, "香蕉"):
            range = (75, 120, 190)
        case (.count, "apple"), (.count, "苹果"):
            range = (100, 180, 280)
        default:
            range = nil
        }
        guard let range else { return nil }
        return HouseholdPortionPrior(
            unit: unit,
            p10Grams: range.0,
            p50Grams: range.1,
            p90Grams: range.2,
            version: PortionEstimator.algorithmVersion
        )
    }
}
