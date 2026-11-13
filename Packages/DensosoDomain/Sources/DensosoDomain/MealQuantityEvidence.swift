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
        personalPrior: HouseholdPortionPrior? = nil,
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
                  isCompatibleUnit(unit, kind: evidence.kind),
                  let prior = applicablePersonalPrior(personalPrior, unit: unit)
                    ?? prior(for: unit, kind: evidence.kind) else {
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

    private func isCompatibleUnit(_ unit: String, kind: MealQuantityEvidence.Kind) -> Bool {
        guard let canonicalUnit = MealPortionPriorCorrection.normalizeSupportedUnit(unit) else {
            return false
        }
        switch kind {
        case .household:
            return ["bowl", "smallbowl", "largebowl", "fist", "palm", "cup", "slice"]
                .contains(canonicalUnit)
        case .count:
            return ["egg", "dumpling", "slice", "banana", "apple"].contains(canonicalUnit)
        default:
            return false
        }
    }

    private func applicablePersonalPrior(
        _ prior: HouseholdPortionPrior?,
        unit: String
    ) -> HouseholdPortionPrior? {
        guard let canonicalUnit = MealPortionPriorCorrection.normalizeSupportedUnit(unit) else {
            return nil
        }
        guard let prior,
              MealPortionPriorCorrection.normalizeSupportedUnit(prior.unit) == canonicalUnit,
              prior.p10Grams.isFinite,
              prior.p50Grams.isFinite,
              prior.p90Grams.isFinite,
              prior.p10Grams > 0,
              prior.p10Grams <= prior.p50Grams,
              prior.p50Grams <= prior.p90Grams,
              prior.p90Grams <= 5_000 else {
            return nil
        }
        return prior
    }

    private func prior(
        for unit: String,
        kind: MealQuantityEvidence.Kind
    ) -> HouseholdPortionPrior? {
        guard let canonicalUnit = MealPortionPriorCorrection.normalizeSupportedUnit(unit) else {
            return nil
        }
        let range: (Double, Double, Double)?
        switch (kind, canonicalUnit) {
        case (.household, "bowl"):
            range = (100, 160, 240)
        case (.household, "smallbowl"):
            range = (70, 120, 180)
        case (.household, "largebowl"):
            range = (150, 230, 340)
        case (.household, "fist"):
            range = (90, 150, 220)
        case (.household, "palm"):
            range = (70, 100, 145)
        case (.household, "cup"):
            range = (180, 240, 320)
        case (.household, "slice"):
            range = (20, 30, 45)
        case (.count, "egg"):
            range = (40, 52, 68)
        case (.count, "dumpling"):
            range = (14, 22, 32)
        case (.count, "slice"):
            range = (20, 30, 45)
        case (.count, "banana"):
            range = (75, 120, 190)
        case (.count, "apple"):
            range = (100, 180, 280)
        default:
            range = nil
        }
        guard let range else { return nil }
        return HouseholdPortionPrior(
            unit: canonicalUnit,
            p10Grams: range.0,
            p50Grams: range.1,
            p90Grams: range.2,
            version: PortionEstimator.algorithmVersion
        )
    }
}
