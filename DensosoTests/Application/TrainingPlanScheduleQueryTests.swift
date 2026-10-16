import Foundation
import SwiftData
import XCTest
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
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let schedule = try await repository.schedule(on: today)

        XCTAssertEqual(schedule.map(\.title), ["多日计划 · 步行", "多日计划 · 休息日"])
        XCTAssertEqual(schedule.map(\.startTime), [at(0, hour: 10), at(0, hour: 18)])
        XCTAssertEqual(schedule.map(\.notes), [
            "目标：30 分钟；地点：户外；建议强度：轻松；理由：计划训练日",
            "休息日",
        ])
        XCTAssertTrue(schedule.allSatisfy { $0.startTime >= today })
        XCTAssertFalse(schedule.contains { $0.title.contains("骑行") || $0.title.contains("跑步") })
        XCTAssertFalse(schedule.contains { $0.notes?.contains(ConfirmedTrainingPlanEntry.notesPrefix) == true })
        XCTAssertTrue(schedule.allSatisfy { ($0.notes?.count ?? 0) <= 600 })
    }
}
