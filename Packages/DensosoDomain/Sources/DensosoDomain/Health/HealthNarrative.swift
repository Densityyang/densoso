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

/// A user's confirmed, subjective check-in. It is separate from objective HealthState.
public struct SubjectiveHealthEntry: Codable, Equatable, Sendable, Identifiable {
    public let dayStart: Date
    public let occurredAt: Date
    public let energy: UserReportedEnergy
    public let stress: UserReportedStress
    public let subjectiveSleep: SubjectiveSleepQuality
    public let evidenceKey: String

    public var id: String { evidenceKey }

    public init(
        dayStart: Date,
        occurredAt: Date,
        energy: UserReportedEnergy,
        stress: UserReportedStress,
        subjectiveSleep: SubjectiveSleepQuality,
        evidenceKey: String
    ) {
        self.dayStart = dayStart
        self.occurredAt = occurredAt
        self.energy = energy
        self.stress = stress
        self.subjectiveSleep = subjectiveSleep
        self.evidenceKey = evidenceKey
    }
}

/// Read-only recent self-reports. The latest confirmed check-in for each local day wins.
public struct SubjectiveHealthContext: Codable, Equatable, Sendable {
    public let asOf: Date
    public let entries: [SubjectiveHealthEntry]

    public init(asOf: Date, entries: [SubjectiveHealthEntry]) {
        self.asOf = asOf
        var seenDays = Set<Date>()
        self.entries = Array(
            entries.sorted {
                if $0.dayStart != $1.dayStart { return $0.dayStart > $1.dayStart }
                return $0.occurredAt > $1.occurredAt
            }
            .filter { seenDays.insert($0.dayStart).inserted }
            .prefix(7)
        )
    }
}

/// Deterministic, local-only inputs supplied to a health narrative request.
/// User preferences are deliberately excluded unless a separate explicit read is made.
/// Subjective check-ins are included only through their separate, explicit read path.
public struct HealthNarrativeContext: Codable, Equatable, Sendable {
    public let healthState: HealthStateV2?
    public let evidence: [EvidenceReference]
    public let recommendationCandidates: [HealthRecommendation]
    public let aggregateSummary: HealthContextSummary?
    public let subjectiveContext: SubjectiveHealthContext?
    public let allowedEvidenceKeys: [String]

    public init(
        healthState: HealthStateV2?,
        evidence: [EvidenceReference],
        recommendationCandidates: [HealthRecommendation],
        aggregateSummary: HealthContextSummary?,
        subjectiveContext: SubjectiveHealthContext? = nil
    ) {
        self.healthState = healthState
        self.subjectiveContext = subjectiveContext
        let subjectiveEvidence = subjectiveContext?.entries.map {
            EvidenceReference(key: $0.evidenceKey, source: "userReportedDailyCheckIn")
        } ?? []
        var seenEvidence = Set<String>()
        self.evidence = Array((subjectiveEvidence + evidence)
            .filter { seenEvidence.insert("\($0.source):\($0.key)").inserted }
            .prefix(48))
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
        case subjectiveContext
        case allowedEvidenceKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            healthState: try container.decodeIfPresent(HealthStateV2.self, forKey: .healthState),
            evidence: try container.decode([EvidenceReference].self, forKey: .evidence),
            recommendationCandidates: try container.decode([HealthRecommendation].self, forKey: .recommendationCandidates),
            aggregateSummary: try container.decodeIfPresent(HealthContextSummary.self, forKey: .aggregateSummary),
            subjectiveContext: try container.decodeIfPresent(SubjectiveHealthContext.self, forKey: .subjectiveContext)
        )
    }
}
