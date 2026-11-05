import Foundation

public enum RecoveryStatus: String, Codable, CaseIterable, Sendable {
    case insufficientEvidence
    case withinTypicalRange
    case attention
}

public enum NextDayState: String, Codable, CaseIterable, Sendable {
    case favorable
    case neutral
    case caution
    case unknown
}

public enum RecommendationAction: String, Codable, CaseIterable, Sendable {
    case continueAsPlanned
    case reduceIntensity
    case rest
    case collectData
}

public struct EvidenceReference: Codable, Equatable, Sendable, Identifiable {
    public let key: String
    public let source: String

    public var id: String { key }

    public init(key: String, source: String) {
        self.key = key
        self.source = source
    }
}

public struct RecoveryAssessment: Codable, Equatable, Sendable {
    public let status: RecoveryStatus
    public let confidence: EstimateConfidence
    public let evidence: [EvidenceReference]
    public let recommendedAction: RecommendationAction
    /// Canonical evidence identifiers that were unavailable when assessing recovery.
    /// Nil preserves compatibility with older persisted summaries.
    public let missingEvidenceKeys: [String]?

    public init(
        status: RecoveryStatus,
        confidence: EstimateConfidence,
        evidence: [EvidenceReference],
        recommendedAction: RecommendationAction,
        missingEvidenceKeys: [String]? = nil
    ) {
        self.status = status
        self.confidence = confidence
        self.evidence = evidence
        self.recommendedAction = recommendedAction
        self.missingEvidenceKeys = missingEvidenceKeys
    }
}

public struct NextDayGuidance: Codable, Equatable, Sendable {
    public let expectedState: NextDayState
    public let confidence: EstimateConfidence
    public let reasons: [EvidenceReference]
    public let recommendedAction: RecommendationAction
    public let conditionalNote: String

    public init(
        expectedState: NextDayState,
        confidence: EstimateConfidence,
        reasons: [EvidenceReference],
        recommendedAction: RecommendationAction,
        conditionalNote: String
    ) {
        self.expectedState = expectedState
        self.confidence = confidence
        self.reasons = reasons
        self.recommendedAction = recommendedAction
        self.conditionalNote = conditionalNote
    }
}

/// A deterministic combination of observed domains and derived recovery/load state.
/// It intentionally has no single numeric health score.
public struct HealthStateV2: Codable, Equatable, Sendable {
    public let domains: [HealthDomainResult]
    public let recovery: RecoveryAssessment
    public let trainingLoad: TrainingLoadSummary
    public let tomorrowGuidance: NextDayGuidance?

    public init(
        domains: [HealthDomainResult],
        recovery: RecoveryAssessment,
        trainingLoad: TrainingLoadSummary,
        tomorrowGuidance: NextDayGuidance?
    ) {
        self.domains = domains
        self.recovery = recovery
        self.trainingLoad = trainingLoad
        self.tomorrowGuidance = tomorrowGuidance
    }
}

/// Cloud-safe state shape whose optional fields follow the user's per-category consent.
/// Unlike `HealthStateV2`, it does not require an Activity-derived training-load value.
public struct CloudHealthStateContext: Codable, Equatable, Sendable {
    public let domains: [HealthDomainResult]
    public let recovery: RecoveryAssessment?
    public let trainingLoad: HealthTrainingLoadContext?
    public let tomorrowGuidance: NextDayGuidance?

    public init(
        domains: [HealthDomainResult],
        recovery: RecoveryAssessment? = nil,
        trainingLoad: HealthTrainingLoadContext? = nil,
        tomorrowGuidance: NextDayGuidance? = nil
    ) {
        self.domains = domains
        self.recovery = recovery
        self.trainingLoad = trainingLoad
        self.tomorrowGuidance = tomorrowGuidance
    }

}

/// Training-load fields suitable for a cloud context. Incomplete coverage never
/// serializes the domain model's zero placeholder as an observed load.
public struct HealthTrainingLoadContext: Codable, Equatable, Sendable {
    public let recentSevenDayLoad: Double?
    public let priorTwentyEightDayAverage: Double?
    public let ratio: Double?
    public let readiness: BaselineReadiness
    public let band: TrainingLoadBand?
    public let dataCoverage: HealthDataCoverage
    public let estimatedWorkoutCount: Int?
    public let unavailableEffortCount: Int?

    public init(
        recentSevenDayLoad: Double?,
        priorTwentyEightDayAverage: Double?,
        ratio: Double?,
        readiness: BaselineReadiness,
        band: TrainingLoadBand?,
        dataCoverage: HealthDataCoverage,
        estimatedWorkoutCount: Int?,
        unavailableEffortCount: Int?
    ) {
        let isComplete = dataCoverage == .complete
        let hasMeasuredLoad = isComplete && readiness != .noData && band != .unavailable
        self.recentSevenDayLoad = hasMeasuredLoad ? recentSevenDayLoad : nil
        self.priorTwentyEightDayAverage = hasMeasuredLoad ? priorTwentyEightDayAverage : nil
        self.ratio = hasMeasuredLoad ? ratio : nil
        self.readiness = readiness
        self.band = isComplete ? band : nil
        self.dataCoverage = dataCoverage
        self.estimatedWorkoutCount = hasMeasuredLoad ? estimatedWorkoutCount : nil
        self.unavailableEffortCount = hasMeasuredLoad ? unavailableEffortCount : nil
    }

    public init(summary: TrainingLoadSummary) {
        let isComplete = summary.dataCoverage == .complete
        let hasMeasuredLoad = isComplete && summary.readiness != .noData && summary.band != .unavailable
        self.init(
            recentSevenDayLoad: hasMeasuredLoad ? summary.recentSevenDayLoad : nil,
            priorTwentyEightDayAverage: hasMeasuredLoad ? summary.priorTwentyEightDayAverage : nil,
            ratio: hasMeasuredLoad ? summary.ratio : nil,
            readiness: summary.readiness,
            band: isComplete ? summary.band : nil,
            dataCoverage: summary.dataCoverage,
            estimatedWorkoutCount: hasMeasuredLoad ? summary.estimatedWorkoutCount : nil,
            unavailableEffortCount: hasMeasuredLoad ? summary.unavailableEffortCount : nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case recentSevenDayLoad
        case priorTwentyEightDayAverage
        case ratio
        case readiness
        case band
        case dataCoverage
        case estimatedWorkoutCount
        case unavailableEffortCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recentSevenDayLoad: try container.decodeIfPresent(Double.self, forKey: .recentSevenDayLoad),
            priorTwentyEightDayAverage: try container.decodeIfPresent(Double.self, forKey: .priorTwentyEightDayAverage),
            ratio: try container.decodeIfPresent(Double.self, forKey: .ratio),
            readiness: try container.decode(BaselineReadiness.self, forKey: .readiness),
            band: try container.decodeIfPresent(TrainingLoadBand.self, forKey: .band),
            dataCoverage: try container.decode(HealthDataCoverage.self, forKey: .dataCoverage),
            estimatedWorkoutCount: try container.decodeIfPresent(Int.self, forKey: .estimatedWorkoutCount),
            unavailableEffortCount: try container.decodeIfPresent(Int.self, forKey: .unavailableEffortCount)
        )
    }
}

/// The cloud and history wire representation of a current-day vital aggregate.
/// It contains no raw samples and withholds citations unless a finite aggregate exists.
public enum HealthVitalAggregateProvenance: String, Codable, Equatable, Sendable {
    case healthKitAggregate
    /// Body mass can be sourced from either local entry or HealthKit; the read model
    /// does not retain enough detail to claim that only one source contributed.
    case localOrHealthKitAggregate
}

public struct HealthVitalTrendContext: Codable, Equatable, Sendable, Identifiable {
    public let metric: HealthVitalMetric
    public let unit: String
    public let sourceProvenance: HealthVitalAggregateProvenance
    public let dataCoverage: HealthDataCoverage
    /// The latest median is calculated from samples for one local calendar day.
    public let currentWindowDays: Int
    public let latestMedian: Double?
    /// Number of samples in the current-day aggregate, when available.
    public let currentSampleCount: Int?
    public let baseline: HealthBaseline
    /// Prior-calendar-day horizon used to populate the baseline; `baseline.validDays`
    /// is the number of populated days actually used (at most 28).
    public let baselineWindowDays: Int
    public let robustZScore: Double?
    public let status: HealthDomainStatus
    public let evidenceKey: String?

    public var id: HealthVitalMetric { metric }

    public init(_ trend: HealthVitalTrend) {
        self.init(
            metric: trend.metric,
            dataCoverage: trend.dataCoverage,
            latestMedian: trend.latestMedian,
            currentSampleCount: trend.currentSampleCount,
            baseline: trend.baseline,
            status: trend.status,
            evidenceKey: trend.evidenceKey
        )
    }

    private init(
        metric: HealthVitalMetric,
        dataCoverage: HealthDataCoverage,
        latestMedian: Double?,
        currentSampleCount: Int?,
        baseline: HealthBaseline,
        status: HealthDomainStatus,
        evidenceKey: String?
    ) {
        self.metric = metric
        unit = Self.unit(for: metric)
        sourceProvenance = Self.provenance(for: metric)
        let resolvedCoverage: HealthDataCoverage
        if dataCoverage == .unknown || status == .unknown {
            resolvedCoverage = .unknown
        } else if dataCoverage == .partial || status == .partial {
            resolvedCoverage = .partial
        } else {
            resolvedCoverage = .complete
        }
        self.dataCoverage = resolvedCoverage
        currentWindowDays = 1
        let hasNumericValue = latestMedian?.isFinite == true
        let expectedEvidenceKey = "vitals.\(metric.rawValue).median"
        let hasValidEvidence = evidenceKey == expectedEvidenceKey
        let canUseMeasurement = resolvedCoverage != .unknown
            && status != .unknown && status != .noData
            && hasNumericValue && hasValidEvidence
        self.latestMedian = canUseMeasurement ? latestMedian : nil
        self.currentSampleCount = canUseMeasurement && (currentSampleCount ?? 0) > 0
            ? currentSampleCount
            : nil
        self.baseline = resolvedCoverage == .unknown
            ? HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
            : baseline
        baselineWindowDays = max(HealthDataWindowContract.analysisLookbackDays - 1, 0)
        robustZScore = canUseMeasurement ? latestMedian.flatMap { baseline.robustZScore(for: $0) } : nil
        if resolvedCoverage == .unknown {
            self.status = .unknown
        } else if resolvedCoverage == .partial {
            self.status = .partial
        } else if !canUseMeasurement && resolvedCoverage == .complete {
            self.status = .noData
        } else {
            self.status = status
        }
        self.evidenceKey = canUseMeasurement ? evidenceKey : nil
    }

    private enum CodingKeys: String, CodingKey {
        case metric
        case unit
        case sourceProvenance
        case dataCoverage
        case currentWindowDays
        case latestMedian
        case currentSampleCount
        case baseline
        case baselineWindowDays
        case robustZScore
        case status
        case evidenceKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metric = try container.decode(HealthVitalMetric.self, forKey: .metric)
        self.init(
            metric: metric,
            dataCoverage: try container.decodeIfPresent(HealthDataCoverage.self, forKey: .dataCoverage) ?? .unknown,
            latestMedian: try container.decodeIfPresent(Double.self, forKey: .latestMedian),
            currentSampleCount: try container.decodeIfPresent(Int.self, forKey: .currentSampleCount),
            baseline: try container.decode(HealthBaseline.self, forKey: .baseline),
            status: try container.decodeIfPresent(HealthDomainStatus.self, forKey: .status) ?? .unknown,
            evidenceKey: try container.decodeIfPresent(String.self, forKey: .evidenceKey)
        )
    }

    private static func unit(for metric: HealthVitalMetric) -> String {
        switch metric {
        case .restingHeartRate: "bpm"
        case .heartRateVariability: "ms"
        case .respiratoryRate: "breaths/min"
        case .wristTemperature: "°C"
        case .bodyWeight: "kg"
        }
    }

    private static func provenance(for metric: HealthVitalMetric) -> HealthVitalAggregateProvenance {
        switch metric {
        case .restingHeartRate, .heartRateVariability, .respiratoryRate, .wristTemperature:
            .healthKitAggregate
        case .bodyWeight:
            .localOrHealthKitAggregate
        }
    }
}

public enum HealthStatePolicy {
    public static func recovery(
        sleep: HealthDomainResult?,
        restingHeartRate: HealthVitalTrend?,
        heartRateVariability: HealthVitalTrend?,
        trainingLoad: TrainingLoadSummary
    ) -> RecoveryAssessment {
        let sleepUsable = sleep.map(isUsableSleep) ?? false
        let restingUsable = restingHeartRate.map(isUsableVital) ?? false
        let variabilityUsable = heartRateVariability.map(isUsableVital) ?? false
        let loadUsable = trainingLoad.dataCoverage == .complete
            && trainingLoad.readiness == .mature
            && trainingLoad.band != .unavailable
            && trainingLoad.ratio?.isFinite == true
        let evidenceCount = [sleepUsable, restingUsable, variabilityUsable, loadUsable].filter { $0 }.count

        let evidence = unique([
            sleep.flatMap {
                isUsableSleep($0)
                    ? $0.evidenceKeys.first.map { EvidenceReference(key: $0, source: "sleep") }
                    : nil
            },
            restingHeartRate.flatMap { isUsableVital($0) ? EvidenceReference(key: $0.evidenceKey, source: "restingHeartRate") : nil },
            heartRateVariability.flatMap { isUsableVital($0) ? EvidenceReference(key: $0.evidenceKey, source: "heartRateVariability") : nil },
            loadUsable ? EvidenceReference(key: "trainingLoad.ratio", source: "trainingLoad") : nil,
        ].compactMap { $0 })

        guard evidenceCount >= 2 else {
            return RecoveryAssessment(
                status: .insufficientEvidence,
                confidence: .low,
                evidence: evidence,
                recommendedAction: .collectData
            )
        }

        let sleepStatus = sleep?.status
        let vitalAttention = (restingUsable && restingHeartRate?.status == .attention)
            || (variabilityUsable && heartRateVariability?.status == .attention)
        let loadElevated = loadUsable
            && (trainingLoad.band == .increased || trainingLoad.band == .sharplyIncreased)
        let loadSharp = loadUsable && trainingLoad.band == .sharplyIncreased
        let sleepChanged = sleepUsable && (sleepStatus == .changed || sleepStatus == .attention)
        let needsCaution = (loadSharp && sleepChanged)
            || (vitalAttention && loadElevated)

        if needsCaution {
            return RecoveryAssessment(
                status: .attention,
                confidence: evidenceCount >= 3 ? .high : .medium,
                evidence: evidence,
                recommendedAction: .reduceIntensity
            )
        }

        guard sleepStatus == .withinTypicalRange,
              sleepUsable,
              loadUsable,
              trainingLoad.band == .nearTypical,
              !vitalAttention,
              restingUsable || variabilityUsable
        else {
            return RecoveryAssessment(
                status: .insufficientEvidence,
                confidence: .low,
                evidence: evidence,
                recommendedAction: .collectData
            )
        }

        return RecoveryAssessment(
            status: .withinTypicalRange,
            confidence: restingUsable && variabilityUsable ? .high : .medium,
            evidence: evidence,
            recommendedAction: .continueAsPlanned,
            missingEvidenceKeys: [
                restingUsable ? nil : "vitals.restingHeartRate.median",
                variabilityUsable ? nil : "vitals.heartRateVariability.median",
            ].compactMap { $0 }
        )
    }

    public static func tomorrowGuidance(
        recovery: RecoveryAssessment,
        trainingLoad: TrainingLoadSummary,
        plannedWorkout: Bool?
    ) -> NextDayGuidance {
        guard let plannedWorkout else {
            return NextDayGuidance(
                expectedState: .unknown,
                confidence: .low,
                reasons: recovery.evidence,
                recommendedAction: .collectData,
                conditionalNote: "明日安排还未确定；可在今晚睡眠情况明确后再决定。"
            )
        }

        guard plannedWorkout else {
            return NextDayGuidance(
                expectedState: .neutral,
                confidence: recovery.confidence,
                reasons: recovery.evidence,
                recommendedAction: .collectData,
                conditionalNote: "目前没有已知训练计划，可根据明早状态再安排活动。"
            )
        }

        if recovery.status == .insufficientEvidence {
            return NextDayGuidance(
                expectedState: .unknown,
                confidence: .low,
                reasons: recovery.evidence,
                recommendedAction: .collectData,
                conditionalNote: "如果今晚睡眠正常，可再评估原计划；目前数据不足以替你判断。"
            )
        }

        if recovery.status == .attention || trainingLoad.band == .increased || trainingLoad.band == .sharplyIncreased {
            return NextDayGuidance(
                expectedState: .caution,
                confidence: recovery.confidence,
                reasons: recovery.evidence,
                recommendedAction: .reduceIntensity,
                conditionalNote: "如果今晚恢复情况没有改善，建议把明天训练调整为轻量。"
            )
        }

        if recovery.status == .withinTypicalRange && trainingLoad.band == .nearTypical {
            return NextDayGuidance(
                expectedState: .favorable,
                confidence: recovery.confidence,
                reasons: recovery.evidence,
                recommendedAction: .continueAsPlanned,
                conditionalNote: "如果今晚睡眠维持正常，明天可以按原计划运动。"
            )
        }

        return NextDayGuidance(
            expectedState: .neutral,
            confidence: .low,
            reasons: recovery.evidence,
            recommendedAction: .collectData,
            conditionalNote: "明天的安排可根据今晚睡眠和早晨状态再调整。"
        )
    }

    private static func isUsable(_ status: HealthDomainStatus) -> Bool {
        status == .withinTypicalRange || status == .changed || status == .attention
    }

    private static func isUsableSleep(_ domain: HealthDomainResult) -> Bool {
        isUsable(domain.status)
            && domain.dataCoverage == .complete
            && domain.currentValue?.isFinite == true
            && domain.evidenceKeys.contains { $0.lowercased().hasPrefix("sleep.") }
    }

    private static func isUsableVital(_ trend: HealthVitalTrend) -> Bool {
        guard isUsable(trend.status),
              trend.dataCoverage == .complete,
              trend.latestMedian?.isFinite == true else { return false }
        return trend.evidenceKey == "vitals.\(trend.metric.rawValue).median"
    }

    private static func unique(_ values: [EvidenceReference]) -> [EvidenceReference] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.key).inserted }
    }
}
