import Foundation
import XCTest
@testable import DensosoDomain

final class HealthStateTests: XCTestCase {
    func testVitalTrendRecordsCurrentSampleCountForItsMedianAggregate() throws {
        let dayStart = Date(timeIntervalSince1970: 1_800_000_000)
        let day = HealthIntelligenceDay(
            dayStart: dayStart,
            restingHeartRateSamples: [61, 62, 63],
            healthReadStates: [HealthMetricID.restingHeartRate.rawValue: .available]
        )

        let result = try XCTUnwrap(HealthIntelligenceEngine().makeDailyBrief(days: [day]))
        let trend = try XCTUnwrap(result.dailyBrief.vitalTrends.first { $0.metric == .restingHeartRate })

        XCTAssertEqual(trend.latestMedian, 62)
        XCTAssertEqual(trend.currentSampleCount, 3)
    }

    func testLocallyVisibleBodyWeightWithUnknownHealthKitScopeIsPartialAndCited() throws {
        let day = HealthIntelligenceDay(
            dayStart: Date(timeIntervalSince1970: 1_800_000_000),
            weightSamplesKilograms: [70.5],
            healthReadStates: [:]
        )

        let result = try XCTUnwrap(HealthIntelligenceEngine().makeDailyBrief(days: [day]))
        let trend = try XCTUnwrap(result.dailyBrief.vitalTrends.first { $0.metric == .bodyWeight })

        XCTAssertEqual(trend.dataCoverage, .partial)
        XCTAssertEqual(trend.status, .partial)
        XCTAssertEqual(trend.latestMedian, 70.5)
        XCTAssertEqual(trend.currentSampleCount, 1)
        XCTAssertEqual(trend.evidenceKey, "vitals.bodyWeight.median")
    }

    func testMissingSleepVitalsAndTrainingLoadRemainUnknown() {
        let result = HealthStatePolicy.recovery(
            sleep: domain(.sleep, status: .noData, evidence: []),
            restingHeartRate: nil,
            heartRateVariability: nil,
            trainingLoad: load(readiness: .noData, band: .unavailable, ratio: nil)
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.recommendedAction, .collectData)
        XCTAssertTrue(result.evidence.isEmpty)
    }

    func testUnknownAndPartialDomainStatusesDoNotBecomeUsableRecoveryEvidence() {
        for status in [HealthDomainStatus.unknown, .partial] {
            let result = HealthStatePolicy.recovery(
                sleep: domain(.sleep, status: status, evidence: []),
                restingHeartRate: nil,
                heartRateVariability: nil,
                trainingLoad: load(readiness: .noData, band: .unavailable, ratio: nil)
            )

            XCTAssertEqual(result.status, .insufficientEvidence)
            XCTAssertEqual(result.recommendedAction, .collectData)
            XCTAssertTrue(result.evidence.isEmpty)
        }

        let unknownLoad = TrainingLoadSummary(
            recentSevenDayLoad: 0,
            priorTwentyEightDayAverage: 100,
            ratio: 1.5,
            readiness: .mature,
            band: .sharplyIncreased,
            estimatedWorkoutCount: 3,
            unavailableEffortCount: 0,
            dataCoverage: .unknown
        )
        let recovery = HealthStatePolicy.recovery(
            sleep: domain(.sleep, status: .unknown, evidence: []),
            restingHeartRate: nil,
            heartRateVariability: nil,
            trainingLoad: unknownLoad
        )
        XCTAssertEqual(recovery.status, .insufficientEvidence)
        XCTAssertTrue(recovery.evidence.isEmpty)
    }

    func testSleepAttentionAndSharpTrainingLoadRecommendReducingIntensity() {
        let recovery = HealthStatePolicy.recovery(
            sleep: domain(.sleep, status: .attention, evidence: ["sleep.mainSleep.minutes"]),
            restingHeartRate: nil,
            heartRateVariability: nil,
            trainingLoad: load(readiness: .mature, band: .sharplyIncreased, ratio: 1.4)
        )

        XCTAssertEqual(recovery.status, .attention)
        XCTAssertEqual(recovery.recommendedAction, .reduceIntensity)
        XCTAssertEqual(recovery.evidence.map(\.key), ["sleep.mainSleep.minutes", "trainingLoad.ratio"])

        let guidance = HealthStatePolicy.tomorrowGuidance(
            recovery: recovery,
            trainingLoad: load(readiness: .mature, band: .sharplyIncreased, ratio: 1.4),
            plannedWorkout: true
        )
        XCTAssertEqual(guidance.expectedState, .caution)
        XCTAssertEqual(guidance.recommendedAction, .reduceIntensity)
    }

    func testTypicalSleepAndTrainingLoadSupportConditionalPlannedWorkout() {
        let sleep = domain(.sleep, status: .withinTypicalRange, evidence: ["sleep.mainSleep.minutes"])
        let recovery = HealthStatePolicy.recovery(
            sleep: sleep,
            restingHeartRate: vital(.restingHeartRate, key: "vitals.restingHeartRate.median"),
            heartRateVariability: vital(.heartRateVariability, key: "vitals.heartRateVariability.median"),
            trainingLoad: load(readiness: .mature, band: .nearTypical, ratio: 1.02)
        )

        XCTAssertEqual(recovery.status, .withinTypicalRange)
        XCTAssertEqual(recovery.confidence, .high)
        let guidance = HealthStatePolicy.tomorrowGuidance(
            recovery: recovery,
            trainingLoad: load(readiness: .mature, band: .nearTypical, ratio: 1.02),
            plannedWorkout: true
        )
        XCTAssertEqual(guidance.expectedState, .favorable)
        XCTAssertEqual(guidance.recommendedAction, .continueAsPlanned)
        XCTAssertTrue(guidance.conditionalNote.contains("如果今晚"))
    }

    func testNormalRecoveryRequiresSleepLoadAndOneUsableVital() {
        let sleep = domain(.sleep, status: .withinTypicalRange, evidence: ["sleep.mainSleep.minutes"])
        let trainingLoad = load(readiness: .mature, band: .nearTypical, ratio: 1.02)

        let withoutVitals = HealthStatePolicy.recovery(
            sleep: sleep,
            restingHeartRate: nil,
            heartRateVariability: nil,
            trainingLoad: trainingLoad
        )
        XCTAssertEqual(withoutVitals.status, .insufficientEvidence)
        XCTAssertEqual(withoutVitals.recommendedAction, .collectData)
        let noPlan = HealthStatePolicy.tomorrowGuidance(
            recovery: withoutVitals,
            trainingLoad: trainingLoad,
            plannedWorkout: true
        )
        XCTAssertEqual(noPlan.expectedState, .unknown)
        XCTAssertEqual(noPlan.recommendedAction, .collectData)

        let restingHeartRateOnly = HealthStatePolicy.recovery(
            sleep: sleep,
            restingHeartRate: vital(.restingHeartRate, key: "vitals.restingHeartRate.median"),
            heartRateVariability: nil,
            trainingLoad: trainingLoad
        )
        XCTAssertEqual(restingHeartRateOnly.status, .withinTypicalRange)
        XCTAssertEqual(restingHeartRateOnly.confidence, .medium)
        XCTAssertEqual(restingHeartRateOnly.missingEvidenceKeys, ["vitals.heartRateVariability.median"])

        let heartRateVariabilityOnly = HealthStatePolicy.recovery(
            sleep: sleep,
            restingHeartRate: nil,
            heartRateVariability: vital(.heartRateVariability, key: "vitals.heartRateVariability.median"),
            trainingLoad: trainingLoad
        )
        XCTAssertEqual(heartRateVariabilityOnly.status, .withinTypicalRange)
        XCTAssertEqual(heartRateVariabilityOnly.confidence, .medium)
        XCTAssertEqual(heartRateVariabilityOnly.missingEvidenceKeys, ["vitals.restingHeartRate.median"])
    }

    func testUnknownOrPartialVitalPairsCannotProduceNormalRecovery() {
        let sleep = domain(.sleep, status: .withinTypicalRange, evidence: ["sleep.mainSleep.minutes"])
        let trainingLoad = load(readiness: .mature, band: .nearTypical, ratio: 1.02)
        let unknownResting = vital(
            .restingHeartRate,
            key: "vitals.restingHeartRate.median",
            status: .unknown
        )
        let unknownVariability = vital(
            .heartRateVariability,
            key: "vitals.heartRateVariability.median",
            status: .unknown
        )
        let partialResting = vital(
            .restingHeartRate,
            key: "vitals.restingHeartRate.median",
            status: .partial
        )
        let partialVariability = vital(
            .heartRateVariability,
            key: "vitals.heartRateVariability.median",
            status: .partial
        )
        let cases: [(String, HealthVitalTrend?, HealthVitalTrend?)] = [
            ("both unknown", unknownResting, unknownVariability),
            ("unknown and partial", unknownResting, partialVariability),
            ("both partial", partialResting, partialVariability),
        ]

        for (name, resting, variability) in cases {
            let recovery = HealthStatePolicy.recovery(
                sleep: sleep,
                restingHeartRate: resting,
                heartRateVariability: variability,
                trainingLoad: trainingLoad
            )
            XCTAssertEqual(recovery.status, .insufficientEvidence, name)
            XCTAssertEqual(recovery.recommendedAction, .collectData, name)
            let guidance = HealthStatePolicy.tomorrowGuidance(
                recovery: recovery,
                trainingLoad: trainingLoad,
                plannedWorkout: true
            )
            XCTAssertEqual(guidance.expectedState, .unknown, name)
            XCTAssertEqual(guidance.recommendedAction, .collectData, name)
        }
    }

    func testUsableAttentionVitalAndElevatedLoadKeepCautionPriority() {
        let recovery = HealthStatePolicy.recovery(
            sleep: domain(.sleep, status: .withinTypicalRange, evidence: ["sleep.mainSleep.minutes"]),
            restingHeartRate: vital(
                .restingHeartRate,
                key: "vitals.restingHeartRate.median",
                status: .attention
            ),
            heartRateVariability: nil,
            trainingLoad: load(readiness: .mature, band: .increased, ratio: 1.3)
        )

        XCTAssertEqual(recovery.status, .attention)
        XCTAssertEqual(recovery.recommendedAction, .reduceIntensity)
    }

    func testAttentionHRVWithUnknownRestingRateCannotProduceNormalRecovery() {
        let sleep = domain(.sleep, status: .withinTypicalRange, evidence: ["sleep.mainSleep.minutes"])
        let trainingLoad = load(readiness: .mature, band: .nearTypical, ratio: 1.02)
        let recovery = HealthStatePolicy.recovery(
            sleep: sleep,
            restingHeartRate: vital(
                .restingHeartRate,
                key: "vitals.restingHeartRate.median",
                status: .unknown
            ),
            heartRateVariability: vital(
                .heartRateVariability,
                key: "vitals.heartRateVariability.median",
                status: .attention
            ),
            trainingLoad: trainingLoad
        )

        XCTAssertEqual(recovery.status, .insufficientEvidence)
        XCTAssertEqual(recovery.recommendedAction, .collectData)
        let guidance = HealthStatePolicy.tomorrowGuidance(
            recovery: recovery,
            trainingLoad: trainingLoad,
            plannedWorkout: true
        )
        XCTAssertEqual(guidance.expectedState, .unknown)
        XCTAssertNotEqual(guidance.recommendedAction, .continueAsPlanned)
    }

    func testGuidanceDoesNotPredictWhenTomorrowPlanIsUnknown() {
        let recovery = HealthStatePolicy.recovery(
            sleep: domain(.sleep, status: .withinTypicalRange, evidence: ["sleep.mainSleep.minutes"]),
            restingHeartRate: nil,
            heartRateVariability: nil,
            trainingLoad: load(readiness: .mature, band: .nearTypical, ratio: 1)
        )

        let guidance = HealthStatePolicy.tomorrowGuidance(
            recovery: recovery,
            trainingLoad: load(readiness: .mature, band: .nearTypical, ratio: 1),
            plannedWorkout: nil
        )

        XCTAssertEqual(guidance.expectedState, .unknown)
        XCTAssertEqual(guidance.recommendedAction, .collectData)
    }

    private func domain(_ domain: HealthDomain, status: HealthDomainStatus, evidence: [String]) -> HealthDomainResult {
        let coverage: HealthDataCoverage = switch status {
        case .unknown: .unknown
        case .partial: .partial
        default: .complete
        }
        return HealthDomainResult(
            domain: domain,
            status: status,
            currentValue: status == .noData ? nil : 7,
            baseline: HealthBaseline(
                readiness: status == .noData ? .noData : .mature,
                validDays: status == .noData ? 0 : 28,
                median: status == .noData ? nil : 7,
                p10: status == .noData ? nil : 6,
                p90: status == .noData ? nil : 8,
                mad: status == .noData ? nil : 0.5
            ),
            evidenceKeys: evidence,
            dataCoverage: coverage
        )
    }

    private func vital(
        _ metric: HealthVitalMetric,
        key: String,
        status: HealthDomainStatus = .withinTypicalRange
    ) -> HealthVitalTrend {
        HealthVitalTrend(
            metric: metric,
            latestMedian: status == .unknown || status == .noData ? nil : 60,
            baseline: HealthBaseline(
                readiness: .mature,
                validDays: 28,
                median: 60,
                p10: 55,
                p90: 65,
                mad: 2
            ),
            status: status,
            evidenceKey: key,
            dataCoverage: status == .unknown ? .unknown : (status == .partial ? .partial : .complete)
        )
    }

    private func load(readiness: BaselineReadiness, band: TrainingLoadBand, ratio: Double?) -> TrainingLoadSummary {
        TrainingLoadSummary(
            recentSevenDayLoad: 100,
            priorTwentyEightDayAverage: readiness == .mature ? 100 : nil,
            ratio: ratio,
            readiness: readiness,
            band: band,
            estimatedWorkoutCount: 0,
            unavailableEffortCount: 0
        )
    }
}
