import Foundation
import XCTest
@testable import DensosoDomain

final class DailyLoopSnapshotTests: XCTestCase {
    func testPhaseChangesAtLocalNoonAndEveningBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let beforeNoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 5, hour: 11, minute: 59
        )))
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 5, hour: 12
        )))
        let beforeEvening = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 5, hour: 17, minute: 59
        )))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 5, hour: 18
        )))

        XCTAssertEqual(DailyLoopPhasePolicy.phase(at: beforeNoon, calendar: calendar), .morning)
        XCTAssertEqual(DailyLoopPhasePolicy.phase(at: noon, calendar: calendar), .daytime)
        XCTAssertEqual(DailyLoopPhasePolicy.phase(at: beforeEvening, calendar: calendar), .daytime)
        XCTAssertEqual(DailyLoopPhasePolicy.phase(at: evening, calendar: calendar), .evening)
        XCTAssertEqual(
            DailyLoopPhasePolicy.phase(at: evening, timezoneIdentifier: "Asia/Shanghai"),
            .evening
        )
    }

    func testMainPRAlgorithmVersionsAreCentralizedAndInvalidateDailyBriefCache() {
        XCTAssertEqual(AlgorithmVersions.calorieAccounting, "calorie-accounting-v3")
        XCTAssertEqual(AlgorithmVersions.dailyMetricsProjection, "daily-metrics-projection-v2")
        XCTAssertEqual(AlgorithmVersions.mealEstimator, "meal-estimator-v2")
        XCTAssertEqual(AlgorithmVersions.portionEstimator, "portion-estimator-v2")
        XCTAssertEqual(AlgorithmVersions.healthIntelligence, "health-intelligence-v6")
        XCTAssertEqual(AlgorithmVersions.recommendationPolicy, "recommendation-policy-v1")
        XCTAssertEqual(AlgorithmVersions.dailyLoop, "daily-loop-v2")
        XCTAssertEqual(RecommendationEngine.algorithmVersion, AlgorithmVersions.recommendationPolicy)
        XCTAssertEqual(DailyLoopSnapshot.currentAlgorithmVersion, AlgorithmVersions.dailyLoop)
        XCTAssertEqual(
            HealthIntelligenceEngine.dailyBriefCacheAlgorithmVersion,
            "health-intelligence-v6+recommendation-policy-v1+metric-window-coverage-v1+activity-independent-metric-trends-v1"
        )
        XCTAssertEqual(
            HealthIntelligenceEngine.weeklyBriefCacheAlgorithmVersion,
            "health-intelligence-v6+activity-independent-metric-trends-v1"
        )
    }

    func testDailyLoopPhasesAndQuickActionsHaveStableCases() {
        XCTAssertEqual(DailyLoopPhase.allCases, [.morning, .daytime, .evening])
        XCTAssertEqual(
            DailyLoopQuickAction.allCases,
            [.logMeal, .logWeight, .planWorkout, .dailyCheckIn]
        )
    }

    func testSnapshotRoundTripsStateGuidanceAndActionSummaries() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let guidance = NextDayGuidance(
            expectedState: .caution,
            confidence: .medium,
            reasons: [EvidenceReference(key: "sleep.coverage", source: "sleep")],
            recommendedAction: .reduceIntensity,
            conditionalNote: "明早再根据状态调整。"
        )
        let healthState = HealthStateV2(
            domains: [],
            recovery: RecoveryAssessment(
                status: .attention,
                confidence: .medium,
                evidence: [EvidenceReference(key: "sleep.coverage", source: "sleep")],
                recommendedAction: .reduceIntensity
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 100,
                priorTwentyEightDayAverage: 80,
                ratio: 1.25,
                readiness: .mature,
                band: .increased,
                estimatedWorkoutCount: 1,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: guidance
        )
        let snapshot = DailyLoopSnapshot(
            dayStart: day,
            timezoneIdentifier: "America/Los_Angeles",
            generatedAt: day.addingTimeInterval(18 * 60 * 60),
            sourceFingerprint: "daily-loop-source-v1",
            projectionVersion: "daily-loop-v2",
            coverage: DailyLoopMetricCoverage(
                intake: .estimated,
                expenditure: .observed,
                deficit: .partial,
                proteinG: .unavailable,
                fatG: .estimated,
                carbsG: .pendingRecompute
            ),
            refreshState: .fresh,
            phase: .evening,
            todayState: DailyStateSummary(
                headline: "恢复状态需要谨慎",
                detail: "可根据现有证据调整明天的训练。",
                healthState: healthState
            ),
            todaySummary: "今天记录了两餐。",
            tomorrowGuidance: guidance,
            pendingActions: [WatchPendingActionSummary(
                actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!,
                title: "确认餐食记录",
                summary: "午餐",
                expiresAt: day.addingTimeInterval(86_400),
                requiresPhoneReview: true
            )],
            workoutPlans: [WatchWorkoutPlanSummary(
                actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000072")!,
                title: "轻松步行",
                scheduledAt: day.addingTimeInterval(86_400),
                state: "scheduled"
            )],
            quickActions: [.logMeal, .logWeight, .planWorkout, .dailyCheckIn]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DailyLoopSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.todayState?.healthState, healthState)
        XCTAssertEqual(decoded.tomorrowGuidance, guidance)
        XCTAssertEqual(decoded.timezoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(decoded.projectionVersion, "daily-loop-v2")
        XCTAssertEqual(decoded.sourceFingerprint, "daily-loop-source-v1")
        XCTAssertEqual(decoded.refreshState, .fresh)
        XCTAssertEqual(decoded.coverage.carbsG, .pendingRecompute)
        XCTAssertEqual(decoded.pendingActions.count, 1)
        XCTAssertEqual(decoded.pendingActions.first?.requiresPhoneReview, true)
        XCTAssertEqual(decoded.workoutPlans.count, 1)
    }

    func testSnapshotSupportsUnavailableOptionalSummaries() throws {
        for phase in [DailyLoopPhase.morning, .daytime] {
            let snapshot = DailyLoopSnapshot(
                dayStart: Date(timeIntervalSince1970: 1_800_000_000),
                phase: phase
            )

            let decoded = try JSONDecoder().decode(
                DailyLoopSnapshot.self,
                from: JSONEncoder().encode(snapshot)
            )

            XCTAssertEqual(decoded.phase, phase)
            XCTAssertNil(decoded.todayState)
            XCTAssertNil(decoded.todaySummary)
            XCTAssertNil(decoded.tomorrowGuidance)
            XCTAssertTrue(decoded.pendingActions.isEmpty)
            XCTAssertTrue(decoded.workoutPlans.isEmpty)
            XCTAssertTrue(decoded.quickActions.isEmpty)
        }
    }

    func testLegacySnapshotDecodesWithUnknownProvenanceAndRefreshRequiredState() throws {
        let data = Data(
            #"{"dayStart":0,"generatedAt":0,"phase":"morning","pendingActions":[],"workoutPlans":[],"quickActions":[]}"#.utf8
        )

        let decoded = try JSONDecoder().decode(DailyLoopSnapshot.self, from: data)

        XCTAssertEqual(decoded.timezoneIdentifier, "unknown")
        XCTAssertEqual(decoded.dayKey, "unknown")
        XCTAssertNil(decoded.sourceFingerprint)
        XCTAssertEqual(decoded.projectionVersion, DailyLoopSnapshot.legacyProjectionVersion)
        XCTAssertEqual(decoded.coverage, .unavailable)
        XCTAssertEqual(decoded.refreshState, .refreshRequired)
    }
}
