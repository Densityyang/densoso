import XCTest
@testable import DensosoDomain

final class HealthStateTests: XCTestCase {
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
        HealthDomainResult(
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
            evidenceKeys: evidence
        )
    }

    private func vital(_ metric: HealthVitalMetric, key: String) -> HealthVitalTrend {
        HealthVitalTrend(
            metric: metric,
            latestMedian: 60,
            baseline: HealthBaseline(
                readiness: .mature,
                validDays: 28,
                median: 60,
                p10: 55,
                p90: 65,
                mad: 2
            ),
            status: .withinTypicalRange,
            evidenceKey: key
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
