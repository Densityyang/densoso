import Foundation
import SwiftData
import XCTest
import DensosoDomain
@testable import Densoso

@MainActor
final class TrainingPlanScheduleQueryTests: XCTestCase {
    func testGetScheduleExpandsConfirmedTrainingPlanForRequestedDayIncludingRestDay() async throws {
        var calendar = Calendar.current
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        func at(_ dayOffset: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }

        let todayWorkoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000211")!
        let plan = TrainingPlanDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000210")!,
            name: "多日计划",
            createdAt: at(-1, hour: 9),
            sessions: [
                TrainingSessionDraft(
                    id: todayWorkoutID,
                    date: at(0, hour: 10),
                    activity: .walking,
                    goal: .timeMinutes(30),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "计划训练日"
                ),
                TrainingSessionDraft(
                    date: at(0, hour: 18),
                    activity: nil,
                    reason: "休息日"
                ),
                TrainingSessionDraft(
                    date: at(1, hour: 9),
                    activity: .cycling,
                    goal: .timeMinutes(40),
                    location: .indoor,
                    recommendedIntensity: .moderate,
                    reason: "明日训练日"
                ),
                TrainingSessionDraft(
                    date: at(2, hour: 9),
                    activity: .running,
                    goal: .timeMinutes(35),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "远期训练日"
                ),
                TrainingSessionDraft(
                    date: at(-1, hour: 18),
                    activity: .walking,
                    goal: .timeMinutes(20),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "昨日训练日"
                ),
            ]
        )
        let entry = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000212")!,
            idempotencyKey: "confirmed-multi-day-plan",
            draft: plan,
            state: .queued
        )
        let singlePlanDate = at(0, hour: 15)
        let singlePlanDraft = WorkoutPlanDraft(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000213")!,
            name: "单次训练计划",
            activity: .walking,
            scheduledAt: singlePlanDate
        )
        let singlePlan = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000214")!,
            idempotencyKey: "confirmed-single-plan",
            draft: singlePlanDraft,
            state: .scheduled
        )
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.insert(
            ScheduleEvent(
                date: at(-1, hour: 9),
                title: plan.name,
                notes: try entry.encodedNotes(),
                startTime: at(-1, hour: 9)
            )
        )
        context.insert(ScheduleEvent(
            date: singlePlanDate,
            title: singlePlanDraft.name,
            notes: try singlePlan.encodedNotes(),
            startTime: singlePlanDate,
            endTime: at(0, hour: 16)
        ))
        context.insert(ScheduleEvent(
            date: at(0, hour: 14),
            title: "普通日程",
            notes: "普通备注",
            startTime: at(0, hour: 14)
        ))
        context.insert(ScheduleEvent(
            date: at(-4, hour: 12),
            title: "更早的普通日程",
            notes: "不应泄漏",
            startTime: at(-4, hour: 12)
        ))
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let schedule = try await repository.schedule(on: today)

        XCTAssertEqual(schedule.map(\.title), ["多日计划 · 步行", "普通日程", "单次训练计划", "多日计划 · 休息日"])
        XCTAssertEqual(schedule.map(\.startTime), [
            at(0, hour: 10), at(0, hour: 14), at(0, hour: 15), at(0, hour: 18),
        ])
        XCTAssertEqual(schedule.map(\.notes), [
            "目标：30 分钟；地点：户外；建议强度：轻松；理由：计划训练日",
            "普通备注",
            nil,
            "休息日",
        ])
        XCTAssertTrue(schedule.allSatisfy { $0.startTime >= today })
        XCTAssertFalse(schedule.contains { $0.title == "更早的普通日程" })
        XCTAssertFalse(schedule.contains { $0.title.contains("骑行") || $0.title.contains("跑步") })
        XCTAssertFalse(schedule.contains { $0.notes?.contains(ConfirmedTrainingPlanEntry.notesPrefix) == true })
        XCTAssertTrue(schedule.allSatisfy { ($0.notes?.count ?? 0) <= 600 })
    }
}
