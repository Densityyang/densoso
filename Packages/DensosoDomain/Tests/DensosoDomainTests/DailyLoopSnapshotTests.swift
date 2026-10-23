import Foundation
import XCTest
@testable import DensosoDomain

final class DailyLoopSnapshotTests: XCTestCase {
    func testMainPRAlgorithmVersionsAreCentralizedAndInvalidateDailyBriefCache() {
        XCTAssertEqual(AlgorithmVersions.calorieAccounting, "calorie-accounting-v2")
        XCTAssertEqual(AlgorithmVersions.dailyMetricsProjection, "daily-metrics-projection-v1")
        XCTAssertEqual(AlgorithmVersions.mealEstimator, "meal-estimator-v2")
        XCTAssertEqual(AlgorithmVersions.portionEstimator, "portion-estimator-v2")
        XCTAssertEqual(AlgorithmVersions.healthIntelligence, "health-intelligence-v2")
        XCTAssertEqual(AlgorithmVersions.recommendationPolicy, "recommendation-policy-v1")
        XCTAssertEqual(AlgorithmVersions.dailyLoop, "daily-loop-v1")
        XCTAssertEqual(RecommendationEngine.algorithmVersion, AlgorithmVersions.recommendationPolicy)
        XCTAssertEqual(DailyLoopSnapshot.currentAlgorithmVersion, AlgorithmVersions.dailyLoop)
        XCTAssertEqual(
            HealthIntelligenceEngine.dailyBriefCacheAlgorithmVersion,
            "health-intelligence-v2+recommendation-policy-v1"
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
            generatedAt: day.addingTimeInterval(18 * 60 * 60),
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
}
