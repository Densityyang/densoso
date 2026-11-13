import Foundation
import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class GetTodayPlanToolTests: XCTestCase {
    func testScheduleFindsHistoricalTrainingSessionAfterFirstPage() async throws {
        var calendar = Calendar.current
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let targetWorkoutDate = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: today))
        let outsideWindowDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let historyStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let fillerPlanCount = SwiftDataAgentRepository.scheduleEventFetchBatchSize

        for index in 0..<fillerPlanCount {
            let eventDate = historyStart.addingTimeInterval(Double(index))
            let draft = TrainingPlanDraft(
                id: fixtureUUID(10_000 + index),
                name: "其他历史计划 \(index)",
                createdAt: eventDate,
                sessions: [TrainingSessionDraft(
                    id: fixtureUUID(20_000 + index),
                    date: outsideWindowDate,
                    activity: .walking,
                    reason: "目标日以外的训练"
                )]
            )
            let entry = ConfirmedTrainingPlanEntry(
                actionID: fixtureUUID(30_000 + index),
                idempotencyKey: "other-historical-plan-\(index)",
                draft: draft,
                state: .queued
            )
            context.insert(ScheduleEvent(
                date: eventDate,
                title: draft.name,
                notes: try entry.encodedNotes(),
                startTime: eventDate
            ))
        }

        let matchingEventDate = historyStart.addingTimeInterval(Double(fillerPlanCount + 1))
        let matchingDraft = TrainingPlanDraft(
            id: fixtureUUID(40_000),
            name: "跨页较早计划",
            createdAt: matchingEventDate,
            sessions: [
                TrainingSessionDraft(
                    id: fixtureUUID(40_001),
                    date: historyStart.addingTimeInterval(-86_400),
                    activity: .running,
                    reason: "更早的计划训练"
                ),
                TrainingSessionDraft(
                    id: fixtureUUID(40_003),
                    date: targetWorkoutDate,
                    activity: .walking,
                    reason: "跨页计划训练"
                ),
            ]
        )
        let matchingEntry = ConfirmedTrainingPlanEntry(
            actionID: fixtureUUID(40_002),
            idempotencyKey: "matching-historical-plan",
            draft: matchingDraft,
            state: .queued
        )
        context.insert(ScheduleEvent(
            date: matchingEventDate,
            title: matchingDraft.name,
            notes: try matchingEntry.encodedNotes(),
            startTime: matchingEventDate
        ))
        let ordinaryEventDate = try XCTUnwrap(calendar.date(bySettingHour: 14, minute: 0, second: 0, of: today))
        context.insert(ScheduleEvent(
            date: ordinaryEventDate,
            title: "今天普通事项",
            notes: "普通日程备注",
            startTime: ordinaryEventDate
        ))
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let schedule = try await repository.schedule(on: today)

        XCTAssertEqual(schedule.map(\.title), ["跨页较早计划 · 步行", "今天普通事项"])
        XCTAssertEqual(schedule.map(\.startTime), [targetWorkoutDate, ordinaryEventDate])
        XCTAssertEqual(schedule.map(\.notes), ["理由：跨页计划训练", "普通日程备注"])
    }

    private func fixtureUUID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", suffix))!
    }
}
