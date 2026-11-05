import Foundation

/// A model-authored explanation of deterministic health facts.
/// Numeric measurements stay in HealthState and are rendered by the app.
public struct HealthNarrative: Codable, Equatable, Sendable {
    public let headline: String
    public let summary: String
    public let recommendations: [HealthNarrativeRecommendation]
    public let tomorrowGuidance: String?
    public let evidenceKeys: [String]

    public init(
        headline: String,
        summary: String,
        recommendations: [HealthNarrativeRecommendation],
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

/// A model may select a locally verified recommendation, but cannot author a
/// new personalized health recommendation without a deterministic evidence link.
public struct HealthNarrativeRecommendation: Codable, Equatable, Sendable {
    public let candidateID: String

    public init(candidateID: String) {
        self.candidateID = candidateID
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

/// Safe, bounded cloud/history representation of one current-day activity metric.
/// It contains only a daily aggregate and baseline, never raw samples.
public struct HealthActivityTrendContext: Codable, Equatable, Sendable, Identifiable {
    public let metric: HealthActivityMetric
    public let unit: String
    public let currentValue: Double?
    public let baselineWindowDays: Int
    public let baseline: HealthBaseline
    public let status: HealthDomainStatus
    public let evidenceKey: String?
    public let dataCoverage: HealthDataCoverage

    public var id: HealthActivityMetric { metric }

    public init(_ trend: ActivityMetricTrend) {
        self.init(
            metric: trend.metric,
            currentValue: trend.currentValue,
            baselineWindowDays: trend.baselineWindowDays,
            baseline: trend.baseline,
            status: trend.status,
            evidenceKey: trend.evidenceKey,
            dataCoverage: trend.dataCoverage
        )
    }

    private init(
        metric: HealthActivityMetric,
        currentValue: Double?,
        baselineWindowDays: Int,
        baseline: HealthBaseline,
        status: HealthDomainStatus,
        evidenceKey: String?,
        dataCoverage: HealthDataCoverage
    ) {
        self.metric = metric
        unit = metric.unit
        let coverage: HealthDataCoverage
        if dataCoverage == .unknown || status == .unknown {
            coverage = .unknown
        } else if dataCoverage == .partial || status == .partial {
            coverage = .partial
        } else {
            coverage = .complete
        }
        self.dataCoverage = coverage
        self.baselineWindowDays = min(max(baselineWindowDays, 0), 28)
        let hasValidEvidence = evidenceKey == metric.evidenceKey
        let validValue = currentValue.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let canUseValue = coverage != .unknown
            && status != .unknown && status != .noData
            && hasValidEvidence && validValue != nil
        self.currentValue = canUseValue ? validValue : nil
        self.baseline = coverage == .unknown
            ? HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
            : baseline
        if coverage == .unknown {
            self.status = .unknown
        } else if coverage == .partial {
            self.status = .partial
        } else if !canUseValue {
            self.status = .noData
        } else {
            self.status = status
        }
        self.evidenceKey = canUseValue ? metric.evidenceKey : nil
    }

    private enum CodingKeys: String, CodingKey {
        case metric
        case unit
        case currentValue
        case baselineWindowDays
        case baseline
        case status
        case evidenceKey
        case dataCoverage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metric = try container.decode(HealthActivityMetric.self, forKey: .metric)
        if let decodedUnit = try container.decodeIfPresent(String.self, forKey: .unit),
           decodedUnit != metric.unit {
            throw DecodingError.dataCorruptedError(
                forKey: .unit,
                in: container,
                debugDescription: "Activity metric unit does not match its metric identifier."
            )
        }
        if let decodedEvidenceKey = try container.decodeIfPresent(String.self, forKey: .evidenceKey),
           decodedEvidenceKey != metric.evidenceKey {
            throw DecodingError.dataCorruptedError(
                forKey: .evidenceKey,
                in: container,
                debugDescription: "Activity evidence key does not match its metric identifier."
            )
        }
        self.init(
            metric: metric,
            currentValue: try container.decodeIfPresent(Double.self, forKey: .currentValue),
            baselineWindowDays: try container.decodeIfPresent(Int.self, forKey: .baselineWindowDays) ?? 0,
            baseline: try container.decodeIfPresent(HealthBaseline.self, forKey: .baseline)
                ?? HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil),
            status: try container.decodeIfPresent(HealthDomainStatus.self, forKey: .status) ?? .unknown,
            evidenceKey: try container.decodeIfPresent(String.self, forKey: .evidenceKey),
            dataCoverage: try container.decodeIfPresent(HealthDataCoverage.self, forKey: .dataCoverage) ?? .unknown
        )
    }
}

/// Deterministic, local-only inputs supplied to a health narrative request.
/// User preferences are deliberately excluded unless a separate explicit read is made.
/// Subjective check-ins are included only through their separate, explicit read path.
public struct HealthNarrativeContext: Codable, Equatable, Sendable {
    public let healthState: HealthStateV2?
    /// Bounded current and personal-baseline aggregates for the supported vital metrics
    /// (resting heart rate, HRV, respiratory rate, wrist temperature, and body weight);
    /// unsupported metrics and raw samples are never included.
    public let vitalTrends: [HealthVitalTrendContext]
    /// Bounded per-metric activity aggregates; old contexts decode with no trends.
    public let activityTrends: [HealthActivityTrendContext]
    /// Per-category safe shape populated after applying cloud consent.
    public let cloudHealthState: CloudHealthStateContext?
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
        subjectiveContext: SubjectiveHealthContext? = nil,
        vitalTrends: [HealthVitalTrend] = [],
        activityTrends: [ActivityMetricTrend] = [],
        cloudHealthState: CloudHealthStateContext? = nil
    ) {
        self.init(
            healthState: healthState,
            evidence: evidence,
            recommendationCandidates: recommendationCandidates,
            aggregateSummary: aggregateSummary,
            subjectiveContext: subjectiveContext,
            safeVitalTrends: vitalTrends.map { HealthVitalTrendContext($0) },
            safeActivityTrends: activityTrends.map { HealthActivityTrendContext($0) },
            cloudHealthState: cloudHealthState
        )
    }

    public init(
        healthState: HealthStateV2?,
        evidence: [EvidenceReference],
        recommendationCandidates: [HealthRecommendation],
        aggregateSummary: HealthContextSummary?,
        subjectiveContext: SubjectiveHealthContext? = nil,
        safeVitalTrends: [HealthVitalTrendContext],
        safeActivityTrends: [HealthActivityTrendContext] = [],
        cloudHealthState: CloudHealthStateContext? = nil
    ) {
        self.healthState = healthState
        self.vitalTrends = Array(safeVitalTrends.prefix(HealthVitalMetric.allCases.count))
        var seenActivityMetrics = Set<HealthActivityMetric>()
        self.activityTrends = Array(safeActivityTrends.filter {
            seenActivityMetrics.insert($0.metric).inserted
        }.prefix(HealthActivityMetric.allCases.count))
        self.cloudHealthState = cloudHealthState
        self.subjectiveContext = subjectiveContext
        let subjectiveEvidence = subjectiveContext?.entries.map {
            EvidenceReference(key: $0.evidenceKey, source: "userReportedDailyCheckIn")
        } ?? []
        let numericVitalEvidence = Set(self.vitalTrends.compactMap(\.evidenceKey))
        let numericActivityEvidence = Set(self.activityTrends.compactMap(\.evidenceKey))
        var seenEvidence = Set<String>()
        self.evidence = Array((subjectiveEvidence + evidence)
            .filter { item in
                let isVitalEvidence = HealthVitalMetric(rawValue: item.source) != nil
                    || item.key.lowercased().hasPrefix("vitals.")
                if isVitalEvidence { return numericVitalEvidence.contains(item.key) }
                let isActivityEvidence = item.source == HealthDomain.activity.rawValue
                    || item.key.lowercased().hasPrefix("activity.")
                guard isActivityEvidence else { return true }
                return item.source == HealthDomain.activity.rawValue
                    && item.key.lowercased().hasPrefix("activity.")
                    && numericActivityEvidence.contains(item.key)
            }
            .filter { seenEvidence.insert("\($0.source):\($0.key)").inserted }
            .prefix(48))
        self.recommendationCandidates = Array(recommendationCandidates.filter { recommendation in
            if recommendation.evidenceKey.lowercased().hasPrefix("vitals.") {
                return numericVitalEvidence.contains(recommendation.evidenceKey)
            }
            if recommendation.evidenceKey.lowercased().hasPrefix("activity.") {
                return recommendation.domain == .activity
                    && numericActivityEvidence.contains(recommendation.evidenceKey)
            }
            return true
        }.prefix(8))
        self.aggregateSummary = aggregateSummary
        self.allowedEvidenceKeys = Array(
            Set(self.evidence.map(\.key) + self.recommendationCandidates.map(\.evidenceKey))
        ).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case healthState
        case vitalTrends
        case activityTrends
        case cloudHealthState
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
            subjectiveContext: try container.decodeIfPresent(SubjectiveHealthContext.self, forKey: .subjectiveContext),
            safeVitalTrends: try container.decodeIfPresent([HealthVitalTrendContext].self, forKey: .vitalTrends) ?? [],
            safeActivityTrends: try container.decodeIfPresent([HealthActivityTrendContext].self, forKey: .activityTrends) ?? [],
            cloudHealthState: try container.decodeIfPresent(CloudHealthStateContext.self, forKey: .cloudHealthState)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(healthState, forKey: .healthState)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(recommendationCandidates, forKey: .recommendationCandidates)
        try container.encodeIfPresent(aggregateSummary, forKey: .aggregateSummary)
        try container.encodeIfPresent(subjectiveContext, forKey: .subjectiveContext)
        try container.encode(vitalTrends, forKey: .vitalTrends)
        try container.encode(activityTrends, forKey: .activityTrends)
        try container.encodeIfPresent(cloudHealthState, forKey: .cloudHealthState)
        try container.encode(allowedEvidenceKeys, forKey: .allowedEvidenceKeys)
    }
}
