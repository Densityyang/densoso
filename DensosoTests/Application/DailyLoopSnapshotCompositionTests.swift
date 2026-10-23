import DensosoDomain
import Foundation
import XCTest
@testable import Densoso

final class DailyLoopSnapshotCompositionTests: XCTestCase {
    func testComposerUsesMatchingExistingBriefAndPreservesOptionalState() throws {
        let calendar = localCalendar()
        let dayStart = try date(2026, 10, 16, 0, 0, calendar: calendar)
        let asOf = try date(2026, 10, 16, 20, 30, calendar: calendar)
        let generatedAt = asOf.addingTimeInterval(17)
        let guidance = NextDayGuidance(
            expectedState: .favorable,
            confidence: .high,
            reasons: [EvidenceReference(key: "sleep.consistency", source: "sleep")],
            recommendedAction: .continueAsPlanned,
            conditionalNote: "如今晚睡眠正常，可按计划活动。"
        )
        let healthState = HealthStateV2(
            domains: [],
            recovery: RecoveryAssessment(
                status: .withinTypicalRange,
                confidence: .high,
                evidence: [],
                recommendedAction: .continueAsPlanned
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 100,
                priorTwentyEightDayAverage: 100,
                ratio: 1,
                readiness: .mature,
                band: .nearTypical,
                estimatedWorkoutCount: 2,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: guidance
        )
        let dailyBrief = makeBrief(dayStart: dayStart, summary: "今天完成了规律饮食和活动。", state: healthState)
        let activeAction = makePendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            createdAt: asOf.addingTimeInterval(-60),
            expiresAt: asOf.addingTimeInterval(3_600),
            state: .pending
        )
        let expiredAction = makePendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            createdAt: asOf.addingTimeInterval(-120),
            expiresAt: asOf.addingTimeInterval(-1),
            state: .pending
        )
        let workoutPlan = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            idempotencyKey: "scheduled-plan",
            draft: WorkoutPlanDraft(
                name: "晚间步行",
                activity: .walking,
                location: .outdoor,
                goal: .timeMinutes(30),
                scheduledAt: asOf.addingTimeInterval(3_600)
            ),
            state: .scheduled
        )
        let terminalPlan = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
            idempotencyKey: "terminal-plan",
            draft: WorkoutPlanDraft(name: "旧计划", activity: .walking),
            state: .terminal
        )
        let tomorrowPlan = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!,
            idempotencyKey: "tomorrow-plan",
            draft: WorkoutPlanDraft(
                name: "明早骑行",
                activity: .cycling,
                location: .outdoor,
                scheduledAt: try date(2026, 10, 17, 9, 0, calendar: calendar)
            ),
            state: .scheduled
        )
        let stalePlan = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!,
            idempotencyKey: "stale-plan",
            draft: WorkoutPlanDraft(
                name: "昨天的旧计划",
                activity: .walking,
                scheduledAt: try date(2026, 10, 15, 18, 0, calendar: calendar)
            ),
            state: .scheduled
        )
        let distantPlan = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000107")!,
            idempotencyKey: "distant-plan",
            draft: WorkoutPlanDraft(
                name: "下周的远期计划",
                activity: .running,
                scheduledAt: try date(2026, 10, 19, 9, 0, calendar: calendar)
            ),
            state: .scheduled
        )

        let snapshot = DailyLoopSnapshotComposer(calendar: calendar).compose(
            asOf: asOf,
            generatedAt: generatedAt,
            dailyBrief: dailyBrief,
            dailyBriefSourceFingerprint: "health-input-fingerprint",
            dailyBriefValidatedAt: asOf.addingTimeInterval(-600),
            coverage: DailyLoopMetricCoverage(
                intake: .estimated,
                expenditure: .observed,
                deficit: .partial,
                proteinG: .estimated,
                fatG: .unavailable,
                carbsG: .pendingRecompute
            ),
            pendingActions: [expiredAction, activeAction],
            workoutPlans: [terminalPlan, distantPlan, stalePlan, tomorrowPlan, workoutPlan]
        )

        XCTAssertEqual(snapshot.dayStart, dayStart)
        XCTAssertEqual(snapshot.dayKey, "2026-10-16")
        XCTAssertEqual(snapshot.timezoneIdentifier, "America/Los_Angeles")
        XCTAssertEqual(snapshot.generatedAt, generatedAt)
        XCTAssertEqual(snapshot.projectionVersion, DailyLoopSnapshot.currentAlgorithmVersion)
        XCTAssertNotNil(snapshot.sourceFingerprint)
        XCTAssertEqual(snapshot.refreshState, .fresh)
        XCTAssertEqual(snapshot.coverage.expenditure, .observed)
        XCTAssertEqual(snapshot.coverage.fatG, .unavailable)
        XCTAssertEqual(snapshot.phase, .evening)
        XCTAssertEqual(snapshot.todaySummary, dailyBrief.summary)
        XCTAssertEqual(snapshot.todayState?.healthState, healthState)
        XCTAssertEqual(snapshot.todayState?.headline, "恢复处于常见范围")
        XCTAssertEqual(snapshot.tomorrowGuidance, guidance)
        XCTAssertEqual(snapshot.pendingActions.map(\.id), [activeAction.id])
        XCTAssertEqual(snapshot.workoutPlans.map(\.id), [workoutPlan.actionID, tomorrowPlan.actionID])
        XCTAssertEqual(snapshot.quickActions, DailyLoopQuickAction.allCases)
    }

    func testComposerKeepsMissingMorningAndDaytimeSummariesNil() throws {
        let calendar = localCalendar()
        let yesterday = try date(2026, 10, 15, 0, 0, calendar: calendar)
        let brief = makeBrief(dayStart: yesterday, summary: "昨天的摘要", state: makeHealthState())
        for (hour, expectedPhase) in [(8, DailyLoopPhase.morning), (15, .daytime)] {
            let asOf = try date(2026, 10, 16, hour, 0, calendar: calendar)
            let snapshot = DailyLoopSnapshotComposer(calendar: calendar).compose(
                asOf: asOf,
                dailyBrief: brief,
                pendingActions: [],
                workoutPlans: []
            )

            XCTAssertEqual(snapshot.phase, expectedPhase)
            XCTAssertEqual(snapshot.refreshState, .refreshRequired)
            XCTAssertNil(snapshot.todayState)
            XCTAssertNil(snapshot.todaySummary)
            XCTAssertNil(snapshot.tomorrowGuidance)
            XCTAssertTrue(snapshot.pendingActions.isEmpty)
            XCTAssertTrue(snapshot.workoutPlans.isEmpty)
        }
    }

    func testComposerMarksOldHealthBriefStaleAndChangesFingerprintWithItsSource() throws {
        let calendar = localCalendar()
        let dayStart = try date(2026, 10, 16, 0, 0, calendar: calendar)
        let asOf = try date(2026, 10, 16, 20, 30, calendar: calendar)
        let brief = makeBrief(dayStart: dayStart, summary: "今天的摘要", state: makeHealthState())
        let composer = DailyLoopSnapshotComposer(calendar: calendar)

        let stale = composer.compose(
            asOf: asOf,
            dailyBrief: brief,
            dailyBriefSourceFingerprint: "old-source",
            dailyBriefValidatedAt: asOf.addingTimeInterval(-7 * 60 * 60),
            pendingActions: [],
            workoutPlans: []
        )
        let changedSource = composer.compose(
            asOf: asOf,
            dailyBrief: brief,
            dailyBriefSourceFingerprint: "new-source",
            dailyBriefValidatedAt: asOf.addingTimeInterval(-600),
            pendingActions: [],
            workoutPlans: []
        )
        let repeated = composer.compose(
            asOf: asOf,
            dailyBrief: brief,
            dailyBriefSourceFingerprint: "new-source",
            dailyBriefValidatedAt: asOf.addingTimeInterval(-600),
            pendingActions: [],
            workoutPlans: []
        )

        XCTAssertEqual(stale.refreshState, .stale)
        XCTAssertEqual(changedSource.refreshState, .fresh)
        XCTAssertNotEqual(stale.sourceFingerprint, changedSource.sourceFingerprint)
        XCTAssertEqual(changedSource.sourceFingerprint, repeated.sourceFingerprint)
    }

    func testComposerCarriesSafeErrorStateWithoutPublishingHealthFingerprint() throws {
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = DailyLoopSnapshotComposer().compose(
            asOf: asOf,
            dailyBrief: nil,
            pendingActions: [],
            workoutPlans: [],
            errorCode: "ProjectionFailed"
        )

        XCTAssertEqual(snapshot.refreshState, .error)
        XCTAssertEqual(snapshot.errorCode, "ProjectionFailed")
        XCTAssertNil(snapshot.sourceFingerprint)
        XCTAssertEqual(snapshot.coverage, .unavailable)
    }

    func testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays() throws {
        let calendar = localCalendar()
        let today = try date(2026, 10, 16, 0, 0, calendar: calendar)
        let asOf = try date(2026, 10, 16, 10, 0, calendar: calendar)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let dayAfterTomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: today))
        let todaySessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let tomorrowSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000112")!

        func trainingSession(
            id: UUID,
            date: Date,
            activity: WorkoutPlanDraft.Activity
        ) -> TrainingSessionDraft {
            TrainingSessionDraft(
                id: id,
                date: date,
                activity: activity,
                goal: .timeMinutes(30),
                location: .outdoor,
                recommendedIntensity: .easy,
                reason: "计划训练日"
            )
        }

        let plan = TrainingPlanDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000110")!,
            name: "三日循环",
            createdAt: asOf,
            sessions: [
                trainingSession(id: UUID(), date: yesterday, activity: .walking),
                trainingSession(id: todaySessionID, date: today.addingTimeInterval(12 * 60 * 60), activity: .walking),
                TrainingSessionDraft(
                    date: today.addingTimeInterval(18 * 60 * 60),
                    activity: nil,
                    reason: "恢复日"
                ),
                trainingSession(id: tomorrowSessionID, date: tomorrow.addingTimeInterval(9 * 60 * 60), activity: .cycling),
                trainingSession(id: UUID(), date: dayAfterTomorrow.addingTimeInterval(9 * 60 * 60), activity: .running),
            ]
        )
        let confirmedPlan = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000113")!,
            idempotencyKey: "training-plan",
            draft: plan,
            state: .queued
        )

        let snapshot = DailyLoopSnapshotComposer(calendar: calendar).compose(
            asOf: asOf,
            dailyBrief: nil,
            pendingActions: [],
            workoutPlans: [],
            trainingPlans: [confirmedPlan]
        )

        XCTAssertEqual(snapshot.workoutPlans.map(\.id), [todaySessionID, tomorrowSessionID])
        XCTAssertEqual(snapshot.workoutPlans.map(\.title), ["三日循环 · 步行", "三日循环 · 骑行"])
        XCTAssertEqual(snapshot.workoutPlans.map(\.state), ["queued", "queued"])
    }

    func testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary() throws {
        let calendar = localCalendar()
        let today = try date(2026, 10, 16, 0, 0, calendar: calendar)
        let asOf = try date(2026, 10, 16, 10, 0, calendar: calendar)
        let plan = TrainingPlanDraft(
            name: "多日计划",
            createdAt: asOf,
            sessions: [
                TrainingSessionDraft(
                    date: today.addingTimeInterval(10 * 60 * 60),
                    activity: .walking,
                    goal: .timeMinutes(30),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "轻松步行"
                ),
                TrainingSessionDraft(
                    date: today.addingTimeInterval(24 * 60 * 60),
                    activity: nil,
                    reason: "休息日"
                ),
            ]
        )
        let action = PendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000120")!,
            idempotencyKey: "pending-training-plan",
            clientRequestID: UUID(),
            createdAt: asOf,
            expiresAt: asOf.addingTimeInterval(3_600),
            payload: .trainingPlan(plan),
            state: .pending
        )

        let snapshot = DailyLoopSnapshotComposer(calendar: calendar).compose(
            asOf: asOf,
            dailyBrief: nil,
            pendingActions: [action],
            workoutPlans: []
        )

        let summary = try XCTUnwrap(snapshot.pendingActions.first)
        XCTAssertEqual(summary.actionID, action.id)
        XCTAssertTrue(summary.requiresPhoneReview == true)
    }

    private func localCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func makeBrief(dayStart: Date, summary: String, state: HealthStateV2) -> DailyHealthBrief {
        let week = HealthContextWindowSummary(
            windowDays: 7,
            coverageDays: [:],
            averageSleepMinutes: nil,
            averageStepCount: nil,
            averageActiveEnergyKcal: nil,
            averageEnergyIntakeKcal: nil,
            averageDailyDeficitKcal: nil,
            averageProteinGrams: nil,
            medianWeightKilograms: nil
        )
        let month = HealthContextWindowSummary(
            windowDays: 28,
            coverageDays: [:],
            averageSleepMinutes: nil,
            averageStepCount: nil,
            averageActiveEnergyKcal: nil,
            averageEnergyIntakeKcal: nil,
            averageDailyDeficitKcal: nil,
            averageProteinGrams: nil,
            medianWeightKilograms: nil
        )
        let contextSummary = HealthContextSummary(
            sevenDay: week,
            twentyEightDay: month,
            targetWeightKilograms: nil,
            dailyDeficitGoalKcal: nil,
            dailyProteinGoalGrams: nil,
            recommendationReferences: []
        )
        return DailyHealthBrief(
            dayStart: dayStart,
            summary: summary,
            domains: state.domains,
            recommendations: [],
            sleep: nil,
            vitalTrends: [],
            trainingLoad: state.trainingLoad,
            contextSummary: contextSummary,
            algorithmVersion: "fixture",
            healthState: state
        )
    }

    private func makeHealthState() -> HealthStateV2 {
        HealthStateV2(
            domains: [],
            recovery: RecoveryAssessment(
                status: .withinTypicalRange,
                confidence: .high,
                evidence: [EvidenceReference(key: "sleep.consistency", source: "sleep")],
                recommendedAction: .continueAsPlanned
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 30,
                priorTwentyEightDayAverage: 30,
                ratio: 1,
                readiness: .mature,
                band: .nearTypical,
                estimatedWorkoutCount: 1,
                unavailableEffortCount: 1
            ),
            tomorrowGuidance: NextDayGuidance(
                expectedState: .favorable,
                confidence: .high,
                reasons: [EvidenceReference(key: "sleep.consistency", source: "sleep")],
                recommendedAction: .continueAsPlanned,
                conditionalNote: "如睡眠正常，可按计划活动。"
            )
        )
    }

    private func makePendingAction(
        id: UUID,
        createdAt: Date,
        expiresAt: Date,
        state: PendingActionState
    ) -> PendingAction {
        PendingAction(
            id: id,
            idempotencyKey: "pending-\(id.uuidString)",
            clientRequestID: UUID(),
            createdAt: createdAt,
            expiresAt: expiresAt,
            payload: .dailyCheckIn(DailyCheckIn(
                occurredAt: createdAt,
                energy: .typical,
                stress: .low,
                subjectiveSleep: .fair
            )),
            state: state
        )
    }
}
