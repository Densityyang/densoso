import Foundation

public enum EvidenceGrade: String, Codable, CaseIterable, Sendable {
    case measured
    case label
    case databaseMatch
    case userReported
    case estimated
    case legacyPointEstimate
    case unresolved
}

public struct EvidenceSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let grade: EvidenceGrade
    public let sourceID: String?
    public let sourceVersion: String?
    public let summary: String
    public let confidence: Double?

    public init(
        id: UUID = UUID(),
        grade: EvidenceGrade,
        sourceID: String? = nil,
        sourceVersion: String? = nil,
        summary: String,
        confidence: Double? = nil
    ) {
        self.id = id
        self.grade = grade
        self.sourceID = sourceID
        self.sourceVersion = sourceVersion
        self.summary = summary
        self.confidence = confidence
    }
}

public struct NutrientEstimate: Codable, Equatable, Sendable {
    public let energyKcal: EstimateRange
    public let proteinGrams: EstimateRange?
    public let fatGrams: EstimateRange?
    public let carbohydrateGrams: EstimateRange?

    public init(
        energyKcal: EstimateRange,
        proteinGrams: EstimateRange? = nil,
        fatGrams: EstimateRange? = nil,
        carbohydrateGrams: EstimateRange? = nil
    ) {
        self.energyKcal = energyKcal
        self.proteinGrams = proteinGrams
        self.fatGrams = fatGrams
        self.carbohydrateGrams = carbohydrateGrams
    }
}
