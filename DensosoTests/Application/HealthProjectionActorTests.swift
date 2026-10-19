import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HealthProjectionActorTests: XCTestCase {
    func testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        for offset in -41...2 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                stepCount: Double(5_000 + offset + 41),
                healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
                algorithmVersion: "projection-actor-fixture-v1"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey(day, calendar: calendar),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "projection-actor-\(offset)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        let futureDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let futureSnapshot = DailyHealthSnapshot(
            dayStart: futureDay,
            timezoneIdentifier: calendar.timeZone.identifier,
            stepCount: 99_999,
            healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
            algorithmVersion: "outside-query-window"
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(futureDay, calendar: calendar),
            timezoneID: futureSnapshot.timezoneIdentifier,
            payloadData: try encoder.encode(futureSnapshot),
            snapshotHash: "outside-query-window",
            algorithmVersion: futureSnapshot.algorithmVersion
        ))
        try context.save()

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let service = HealthIntelligenceService(modelContainer: container, calendar: calendar)
        let beforeDailyBriefs = try context.fetchCount(FetchDescriptor<DailyBriefRecord>())
        let beforeWeeklyBriefs = try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>())

        let actorState = try await actor.todayHealthState(asOf: today)
        let narrativeContext = try await actor.healthNarrativeContext(asOf: today)
        let actorHistory = try await actor.healthHistory(from: start, through: today)
        let serviceHistory = try await service.healthHistory(from: start, through: today)

        XCTAssertNotNil(actorState)
        XCTAssertEqual(narrativeContext.healthState, actorState)
        XCTAssertNotNil(narrativeContext.aggregateSummary)
        XCTAssertEqual(actorHistory, serviceHistory)
        XCTAssertEqual(actorHistory.map(\.date), [
            start,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start)),
            today,
        ])
        XCTAssertEqual(
            actorState?.domains.first(where: { $0.domain == .activity })?.currentValue,
            5_043
        )
        XCTAssertFalse(actorHistory.contains { $0.state.domains.contains { $0.currentValue == 99_999 } })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), beforeDailyBriefs)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>()), beforeWeeklyBriefs)
    }

    func testActorHistoryRetainsExistingRangeValidation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let actor = HealthProjectionActor(modelContainer: container)
        let today = Calendar.current.startOfDay(for: Date())
        let oversizedStart = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -14, to: today))

        do {
            _ = try await actor.healthHistory(from: oversizedStart, through: today)
            XCTFail("Expected the existing fourteen-day bound to reject this query")
        } catch {
            XCTAssertEqual(error as? HealthHistoryQueryError, .rangeTooLarge)
        }
    }

    func testHealthContextSummaryAggregatesMealProteinAcrossStableFetchPages() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let mealDate = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let mealCount = HealthIntelligenceReadModel.mealFetchBatchSize + 1
        for index in 0..<mealCount {
            context.insert(MealRecord(
                date: mealDate,
                totalCaloriesKcal: 100,
                sourceActionKey: String(format: "projection-meal-%04d", index),
                proteinLikelyG: 2
            ))
        }
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let incompleteMealDate = try XCTUnwrap(
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: previousDay)
        )
        context.insert(MealRecord(
            date: incompleteMealDate,
            totalCaloriesKcal: 100,
            sourceActionKey: "projection-meal-incomplete-protein"
        ))
        try context.save()

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let result = try await actor.healthContextSummary(asOf: mealDate)
        let summary = try XCTUnwrap(result)

        XCTAssertEqual(summary.sevenDay.averageProteinGrams, Double(mealCount * 2))
    }

    func testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let todayWorkout = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A01")!,
            idempotencyKey: "daily-loop-today-workout",
            draft: WorkoutPlanDraft(
                name: "今日步行",
                activity: .walking,
                scheduledAt: today.addingTimeInterval(12 * 60 * 60)
            )
        )
        let tomorrowWorkout = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A02")!,
            idempotencyKey: "daily-loop-tomorrow-workout",
            draft: WorkoutPlanDraft(
                name: "明日骑行",
                activity: .cycling,
                scheduledAt: tomorrow.addingTimeInterval(9 * 60 * 60)
            )
        )
        let olderTrainingSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000A21")!
        let newerTrainingSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000A22")!
        let olderTrainingPlan = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A03")!,
            idempotencyKey: "daily-loop-older-training-plan",
            draft: TrainingPlanDraft(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000A13")!,
                name: "旧多日计划",
                createdAt: today.addingTimeInterval(-200),
                sessions: [TrainingSessionDraft(id: olderTrainingSessionID, date: today, activity: .walking, reason: "计划训练")]
            )
        )
        let newerTrainingPlan = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A04")!,
            idempotencyKey: "daily-loop-newer-training-plan",
            draft: TrainingPlanDraft(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000A14")!,
                name: "新多日计划",
                createdAt: today.addingTimeInterval(-100),
                sessions: [
                    TrainingSessionDraft(id: newerTrainingSessionID, date: today, activity: .cycling, reason: "计划骑行"),
                    TrainingSessionDraft(date: tomorrow, activity: nil, reason: "休息日"),
                ]
            )
        )

        context.insert(ScheduleEvent(
            date: today,
            title: "普通日程",
            notes: "not-a-confirmed-plan",
            startTime: today
        ))
        context.insert(ScheduleEvent(
            date: today,
            title: olderTrainingPlan.draft.name,
            notes: try olderTrainingPlan.encodedNotes(),
            startTime: today
        ))
        context.insert(ScheduleEvent(
            date: tomorrow,
            title: tomorrowWorkout.draft.name,
            notes: try tomorrowWorkout.encodedNotes(),
            startTime: tomorrow
        ))
        context.insert(ScheduleEvent(
            date: today,
            title: todayWorkout.draft.name,
            notes: try todayWorkout.encodedNotes(),
            startTime: today
        ))
        context.insert(ScheduleEvent(
            date: today,
            title: newerTrainingPlan.draft.name,
            notes: try newerTrainingPlan.encodedNotes(),
            startTime: today
        ))
        try context.save()
        let countBefore = try context.fetchCount(FetchDescriptor<ScheduleEvent>())

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let plans = try await actor.confirmedPlanEntries()

        XCTAssertEqual(plans.workoutPlans.map(\.actionID), [tomorrowWorkout.actionID, todayWorkout.actionID])
        XCTAssertEqual(plans.trainingPlans.map(\.actionID), [newerTrainingPlan.actionID, olderTrainingPlan.actionID])
        XCTAssertEqual(plans.trainingPlans.first?.draft.sessions.count, 2)

        let asOf = today.addingTimeInterval(10 * 60 * 60)
        let activeAction = PendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000A05")!,
            idempotencyKey: "daily-loop-active-action",
            clientRequestID: UUID(),
            createdAt: asOf.addingTimeInterval(-60),
            expiresAt: asOf.addingTimeInterval(3_600),
            payload: .trainingPlan(newerTrainingPlan.draft),
            state: .pending
        )
        let expiredAction = PendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000A06")!,
            idempotencyKey: "daily-loop-expired-action",
            clientRequestID: UUID(),
            createdAt: asOf.addingTimeInterval(-120),
            expiresAt: asOf.addingTimeInterval(-1),
            payload: .trainingPlan(olderTrainingPlan.draft),
            state: .pending
        )
        let snapshot = try await actor.dailyLoopSnapshot(
            asOf: asOf,
            dailyBrief: nil,
            pendingActions: [expiredAction, activeAction]
        )
        XCTAssertEqual(snapshot.phase, .morning)
        XCTAssertNil(snapshot.todaySummary)
        XCTAssertEqual(snapshot.pendingActions.map(\.actionID), [activeAction.id])
        XCTAssertTrue(snapshot.pendingActions.first?.requiresPhoneReview == true)
        XCTAssertEqual(snapshot.workoutPlans.map(\.actionID), [
            olderTrainingSessionID,
            newerTrainingSessionID,
            todayWorkout.actionID,
            tomorrowWorkout.actionID,
        ])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleEvent>()), countBefore)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<ScheduleEvent>()).first(where: { $0.title == "普通日程" })?.notes,
            "not-a-confirmed-plan"
        )
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
