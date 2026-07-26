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

    public init(id: UUID = UUID(), kind: Kind, value: String, confidence: Double, capturedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.value = value
        self.confidence = min(1, max(0, confidence))
        self.capturedAt = capturedAt
    }
}

/// A range is required when no scale, depth, planar reference, or package
/// serving size can support an exact portion.
public struct PortionEstimate: Codable, Equatable, Sendable {
    public let lowGrams: Double
    public let likelyGrams: Double
    public let highGrams: Double
    public let isMeasured: Bool

    public init(lowGrams: Double, likelyGrams: Double, highGrams: Double, isMeasured: Bool) throws {
        guard lowGrams >= 0, lowGrams <= likelyGrams, likelyGrams <= highGrams else {
            throw MealEvidenceError.invalidPortionRange
        }
        self.lowGrams = lowGrams
        self.likelyGrams = likelyGrams
        self.highGrams = highGrams
        self.isMeasured = isMeasured
    }
}

public enum MealClarification: String, CaseIterable, Codable, Sendable {
    case foodIdentity
    case portion
    case cookingMethod
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
}

public enum MealEvidenceError: Error, Equatable, Sendable {
    case invalidPortionRange
}
