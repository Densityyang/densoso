import Foundation

/// A model-authored explanation of deterministic health facts.
/// Numeric measurements stay in HealthState and are rendered by the app.
public struct HealthNarrative: Codable, Equatable, Sendable {
    public let headline: String
    public let summary: String
    public let recommendations: [String]
    public let tomorrowGuidance: String?
    public let evidenceKeys: [String]

    public init(
        headline: String,
        summary: String,
        recommendations: [String],
        tomorrowGuidance: String?,
        evidenceKeys: [String]
    ) {
        self.headline = headline
        self.summary = summary
        self.recommendations = recommendations
        self.tomorrowGuidance = tomorrowGuidance
        self.evidenceKeys = evidenceKeys
    }
}

/// Deterministic, local-only inputs supplied to a health narrative request.
/// User preferences are deliberately excluded unless a separate explicit read is made.
public struct HealthNarrativeContext: Codable, Equatable, Sendable {
    public let healthState: HealthStateV2?
    public let evidence: [EvidenceReference]
    public let recommendationCandidates: [HealthRecommendation]
    public let aggregateSummary: HealthContextSummary?
    public let allowedEvidenceKeys: [String]

    public init(
        healthState: HealthStateV2?,
        evidence: [EvidenceReference],
        recommendationCandidates: [HealthRecommendation],
        aggregateSummary: HealthContextSummary?
    ) {
        self.healthState = healthState
        var seenEvidence = Set<String>()
        self.evidence = Array(evidence.filter { seenEvidence.insert("\($0.source):\($0.key)").inserted }.prefix(48))
        self.recommendationCandidates = Array(recommendationCandidates.prefix(8))
        self.aggregateSummary = aggregateSummary
        self.allowedEvidenceKeys = Array(
            Set(self.evidence.map(\.key) + self.recommendationCandidates.map(\.evidenceKey))
        ).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case healthState
        case evidence
        case recommendationCandidates
        case aggregateSummary
        case allowedEvidenceKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            healthState: try container.decodeIfPresent(HealthStateV2.self, forKey: .healthState),
            evidence: try container.decode([EvidenceReference].self, forKey: .evidence),
            recommendationCandidates: try container.decode([HealthRecommendation].self, forKey: .recommendationCandidates),
            aggregateSummary: try container.decodeIfPresent(HealthContextSummary.self, forKey: .aggregateSummary)
        )
    }
}
