import Foundation

/// Sanitized meal-capture evidence. It contains extracted text or identifiers,
/// never raw photos, EXIF, location, prompts, or executable instructions.
public struct MealEvidence: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case barcode
        case nutritionLabel
        case foodCandidate
        case portionReference
        case voiceTranscript
        case manualEntry
    }

    public let id: UUID
    public let kind: Kind
    public let value: String
    public let confidence: Double
    public let capturedAt: Date
    public let sourceVersion: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        value: String,
        confidence: Double,
        capturedAt: Date = Date(),
        sourceVersion: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.confidence = min(1, max(0, confidence))
        self.capturedAt = capturedAt
        self.sourceVersion = sourceVersion
    }
}

/// A range is required when no scale, depth, planar reference, or package
/// serving size can support an exact portion.
public struct PortionEstimate: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case userCorrection
        case measured
        case userReportedExact
        case approximateGrams
        case packageServing
        case householdPrior
        case modelEstimate
        case photoWithScale
        case photoWithoutScale
    }

    public let lowGrams: Double
    public let likelyGrams: Double
    public let highGrams: Double
    public let isMeasured: Bool
    public let source: Source
    public let conflicts: [String]

    public init(
        lowGrams: Double,
        likelyGrams: Double,
        highGrams: Double,
        isMeasured: Bool,
        source: Source = .photoWithoutScale,
        conflicts: [String] = []
    ) throws {
        guard lowGrams.isFinite, likelyGrams.isFinite, highGrams.isFinite,
              lowGrams >= 0, lowGrams <= likelyGrams, likelyGrams <= highGrams else {
            throw MealEvidenceError.invalidPortionRange
        }
        self.lowGrams = lowGrams
        self.likelyGrams = likelyGrams
        self.highGrams = highGrams
        self.isMeasured = isMeasured
        self.source = source
        self.conflicts = conflicts
    }
}

public enum MealClarification: String, CaseIterable, Codable, Sendable {
    case foodIdentity
    case portion
    case cookingMethod
    case hiddenIngredient
    case preparation
}

public struct ClarificationCandidate: Codable, Equatable, Sendable {
    public let kind: MealClarification
    public let prompt: String
    public let expectedEnergyRangeReduction: Double
    public let userEffort: Double

    public init(
        kind: MealClarification,
        prompt: String,
        expectedEnergyRangeReduction: Double,
        userEffort: Double
    ) {
        self.kind = kind
        self.prompt = prompt
        self.expectedEnergyRangeReduction = min(max(expectedEnergyRangeReduction, 0), 1)
        self.userEffort = max(userEffort, 0.01)
    }

    public var valueScore: Double { expectedEnergyRangeReduction / userEffort }
}

public struct ClarificationContext: Codable, Equatable, Sendable {
    public let energyKcal: EstimateRange
    public let candidates: [ClarificationCandidate]

    public init(energyKcal: EstimateRange, candidates: [ClarificationCandidate]) {
        self.energyKcal = energyKcal
        self.candidates = candidates
    }
}

public struct ClarificationQuestion: Codable, Equatable, Sendable {
    public let kind: MealClarification
    public let prompt: String

    public init(kind: MealClarification, prompt: String) {
        self.kind = kind
        self.prompt = prompt
    }
}

/// Selects only the highest-value missing fact per turn, keeping the user in
/// control of what becomes a draft without inventing an exact kcal value.
public struct ClarificationSelector: Sendable {
    public init() {}

    public func nextQuestion(
        candidates: [MealEvidence],
        portion: PortionEstimate?,
        cookingMethod: String?
    ) -> MealClarification? {
        let hasIdentity = candidates.contains { $0.kind == .barcode || ($0.kind == .foodCandidate && $0.confidence >= 0.7) }
        if !hasIdentity { return .foodIdentity }
        if portion == nil || portion?.isMeasured == false { return .portion }
        if cookingMethod?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return .cookingMethod }
        return nil
    }

    public func selectOne(from context: ClarificationContext) -> ClarificationQuestion? {
        let relativeWidth = (context.energyKcal.high - context.energyKcal.low)
            / max(context.energyKcal.likely, 1)
        guard relativeWidth > 0.65 else { return nil }
        let selected = context.candidates
            .filter { $0.expectedEnergyRangeReduction >= 0.20 }
            .sorted {
                if abs($0.valueScore - $1.valueScore) > 0.000_001 {
                    return $0.valueScore > $1.valueScore
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
            .first
        return selected.map { ClarificationQuestion(kind: $0.kind, prompt: $0.prompt) }
    }
}

public enum MealEvidenceError: Error, Equatable, Sendable {
    case invalidPortionRange
    case missingPortionEvidence
}
