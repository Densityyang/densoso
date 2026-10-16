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

    public init(
        status: RecoveryStatus,
        confidence: EstimateConfidence,
        evidence: [EvidenceReference],
        recommendedAction: RecommendationAction
    ) {
        self.status = status
        self.confidence = confidence
        self.evidence = evidence
        self.recommendedAction = recommendedAction
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

public enum HealthStatePolicy {
    public static func recovery(
        sleep: HealthDomainResult?,
        restingHeartRate: HealthVitalTrend?,
        heartRateVariability: HealthVitalTrend?,
        trainingLoad: TrainingLoadSummary
    ) -> RecoveryAssessment {
        let sleepUsable = sleep.map { isUsable($0.status) } ?? false
        let restingUsable = restingHeartRate.map { isUsable($0.status) } ?? false
        let variabilityUsable = heartRateVariability.map { isUsable($0.status) } ?? false
        let loadUsable = trainingLoad.readiness == .mature && trainingLoad.band != .unavailable
        let evidenceCount = [sleepUsable, restingUsable, variabilityUsable, loadUsable].filter { $0 }.count

        let evidence = unique([
            sleep.flatMap {
                isUsable($0.status)
                    ? $0.evidenceKeys.first.map { EvidenceReference(key: $0, source: "sleep") }
                    : nil
            },
            restingHeartRate.flatMap { isUsable($0.status) ? EvidenceReference(key: $0.evidenceKey, source: "restingHeartRate") : nil },
            heartRateVariability.flatMap { isUsable($0.status) ? EvidenceReference(key: $0.evidenceKey, source: "heartRateVariability") : nil },
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
        let vitalAttention = restingHeartRate?.status == .attention
            || heartRateVariability?.status == .attention
        let loadElevated = trainingLoad.band == .increased || trainingLoad.band == .sharplyIncreased
        let loadSharp = trainingLoad.band == .sharplyIncreased
        let sleepAttention = sleepStatus == .attention
        let sleepChanged = sleepStatus == .changed || sleepAttention
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
              trainingLoad.band == .nearTypical,
              !vitalAttention
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
            confidence: evidenceCount >= 3 ? .high : .medium,
            evidence: evidence,
            recommendedAction: .continueAsPlanned
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

    private static func unique(_ values: [EvidenceReference]) -> [EvidenceReference] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.key).inserted }
    }
}
