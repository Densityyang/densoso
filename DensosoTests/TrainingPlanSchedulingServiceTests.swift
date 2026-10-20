import DensosoDomain
import SwiftData
import WorkoutKit
import XCTest
@testable import Densoso

@MainActor
final class TrainingPlanSchedulingServiceTests: XCTestCase {
    func testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry() async throws {
        let (container, service, client) = try makeService()
        let actionID = UUID()
        let draft = makeDraft()
        try insertConfirmedPlan(actionID: actionID, draft: draft, in: container)

        XCTAssertEqual(try service.confirmedPlans().map(\.actionID), [actionID])
        try await service.scheduleConfirmedPlan(actionID: actionID)

        XCTAssertEqual(client.authorizationCount, 1)
        XCTAssertEqual(client.scheduledDates, [draft.sessions[0].date, draft.sessions[2].date])
        XCTAssertEqual(client.scheduledPlanIDs, Set([draft.sessions[0].id, draft.sessions[2].id]))
        let entry = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) }
                .first
        )
        XCTAssertEqual(entry.state, .scheduled)
        XCTAssertEqual(Set(entry.scheduledSessionIDs), client.scheduledPlanIDs)
        XCTAssertEqual(entry.draft.sessions.count, 3)
    }

    func testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays() async throws {
        let (container, service, client) = try makeService()
        let actionID = UUID()
        let draft = makeDraft()
        try insertConfirmedPlan(actionID: actionID, draft: draft, in: container)
        client.failOnCall = 2

        do {
            try await service.scheduleConfirmedPlan(actionID: actionID)
            XCTFail("Expected the second session schedule to fail")
        } catch {
            XCTAssertEqual(error as? TrainingPlanSchedulingTestError, .injected)
        }
        let interrupted = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) }
                .first
        )
        XCTAssertEqual(interrupted.state, .retryable)
        XCTAssertEqual(interrupted.scheduledSessionIDs, [draft.sessions[0].id])

        client.failOnCall = nil
        try await service.scheduleConfirmedPlan(actionID: actionID)

        XCTAssertEqual(client.scheduledPlanIDs, Set([draft.sessions[0].id, draft.sessions[2].id]))
        XCTAssertEqual(client.scheduledDates.count, 2)
        XCTAssertEqual(client.authorizationCount, 2)
        let resumed = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) }
                .first
        )
        XCTAssertEqual(resumed.state, .scheduled)
    }

    func testConfirmedPlanHistoryPagesAcrossThe64EventBoundary() async throws {
        let (container, service, client) = try makeService()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var actionIDs: [UUID] = []
        var finalSessionID: UUID?

        for index in 0..<65 {
            let actionID = UUID()
            let createdAt = start.addingTimeInterval(TimeInterval(index))
            let sessionID = UUID()
            let draft = TrainingPlanDraft(
                name: "计划 \(index)",
                createdAt: createdAt,
                sessions: [
                    TrainingSessionDraft(
                        id: sessionID,
                        date: createdAt,
                        activity: .walking,
                        goal: .timeMinutes(30),
                        location: .outdoor,
                        recommendedIntensity: .easy,
                        reason: "保持轻松步行。"
                    ),
                ]
            )
            let entry = ConfirmedTrainingPlanEntry(
                actionID: actionID,
                idempotencyKey: "training-plan-\(actionID.uuidString.lowercased())",
                draft: draft
            )
            context.insert(ScheduleEvent(
                date: createdAt,
                title: draft.name,
                notes: try entry.encodedNotes(),
                startTime: createdAt
            ))
            actionIDs.append(actionID)
            if index == 64 { finalSessionID = sessionID }
        }
        context.insert(ScheduleEvent(date: start, title: "普通日程", notes: "普通备注", startTime: start))
        try context.save()

        let confirmed = try service.confirmedPlans()
        XCTAssertEqual(confirmed.count, 65)
        XCTAssertEqual(confirmed.map(\.actionID), Array(actionIDs.reversed()))

        let targetActionID = try XCTUnwrap(actionIDs.last)
        let targetSessionID = try XCTUnwrap(finalSessionID)
        try await service.scheduleConfirmedPlan(actionID: targetActionID)
        XCTAssertEqual(client.authorizationCount, 1)
        XCTAssertEqual(client.scheduledPlanIDs, Set([targetSessionID]))
        XCTAssertEqual(client.scheduledDates, [start.addingTimeInterval(64)])
    }

    func testUpcomingTrainingSessionsAreBoundedAndOrderedAcrossPages() throws {
        let (container, service, _) = try makeService()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(14 * 86_400)

        func workoutSession(id: UUID, date: Date) -> TrainingSessionDraft {
            TrainingSessionDraft(
                id: id,
                date: date,
                activity: .walking,
                goal: .timeMinutes(30),
                location: .outdoor,
                recommendedIntensity: .easy,
                reason: "保持轻松步行。"
            )
        }

        for index in 0..<64 {
            let eventDate = start.addingTimeInterval(-Double(index + 2) * 86_400)
            let actionID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 1_000 + index))!
            let sessionID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 2_000 + index))!
            let draft = TrainingPlanDraft(
                name: "已结束计划 \(index)",
                createdAt: eventDate,
                sessions: [workoutSession(id: sessionID, date: eventDate)]
            )
            let entry = ConfirmedTrainingPlanEntry(
                actionID: actionID,
                idempotencyKey: "terminal-\(index)",
                draft: draft,
                state: .terminal
            )
            context.insert(ScheduleEvent(
                date: eventDate,
                title: draft.name,
                notes: try entry.encodedNotes(),
                startTime: eventDate
            ))
        }

        let terminalStart = start.addingTimeInterval(-36 * 3_600)
        let terminalInRangeDraft = TrainingPlanDraft(
            name: "窗口内但已终止",
            createdAt: terminalStart,
            sessions: [
                workoutSession(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000008101")!,
                    date: terminalStart
                ),
                workoutSession(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000008102")!,
                    date: start.addingTimeInterval(86_400)
                ),
            ]
        )
        let terminalInRangeEntry = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000008100")!,
            idempotencyKey: "terminal-in-range",
            draft: terminalInRangeDraft,
            state: .terminal
        )
        context.insert(ScheduleEvent(
            date: terminalStart,
            title: terminalInRangeDraft.name,
            notes: try terminalInRangeEntry.encodedNotes(),
            startTime: terminalStart
        ))

        let matchingDate = start.addingTimeInterval(9 * 3_600)
        let planActionID = UUID(uuidString: "00000000-0000-0000-0000-000000008200")!
        let firstSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000008201")!
        let secondSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000008202")!
        var planSessions = [
            workoutSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000008204")!,
                date: start.addingTimeInterval(-86_400)
            ),
            workoutSession(id: secondSessionID, date: matchingDate),
            TrainingSessionDraft(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000008205")!,
                date: start.addingTimeInterval(5 * 86_400),
                activity: nil,
                reason: "恢复日。"
            ),
            workoutSession(id: firstSessionID, date: matchingDate),
        ]
        for dayOffset in 2...10 {
            let sessionID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 8_300 + dayOffset))!
            planSessions.append(workoutSession(
                id: sessionID,
                date: start.addingTimeInterval(Double(dayOffset) * 86_400 + 9 * 3_600)
            ))
        }
        let boundarySessionID = UUID(uuidString: "00000000-0000-0000-0000-000000008399")!
        planSessions.append(workoutSession(id: boundarySessionID, date: end))
        let draft = TrainingPlanDraft(
            name: "窗口内计划",
            createdAt: start.addingTimeInterval(-3_600),
            sessions: planSessions
        )
        let entry = ConfirmedTrainingPlanEntry(
            actionID: planActionID,
            idempotencyKey: "window-plan",
            draft: draft
        )
        let eventDate = try XCTUnwrap(draft.sessions.map(\.date).min())
        context.insert(ScheduleEvent(
            date: eventDate,
            title: draft.name,
            notes: try entry.encodedNotes(),
            startTime: eventDate
        ))
        context.insert(ScheduleEvent(date: start, title: "普通日程", notes: "普通备注", startTime: start))
        try context.save()

        let sessions = try service.upcomingConfirmedSessions(in: start..<end, limit: 10)

        let expectedSessionIDs = [firstSessionID, secondSessionID] + (2...9).map { dayOffset in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 8_300 + dayOffset))!
        }
        XCTAssertEqual(sessions.map(\.sessionID), expectedSessionIDs)
        XCTAssertEqual(sessions.map(\.planActionID), Array(repeating: planActionID, count: 10))
        XCTAssertTrue(sessions.allSatisfy { $0.state == .queued })
        let allWindowSessions = try service.upcomingConfirmedSessions(in: start..<end, limit: 20)
        XCTAssertEqual(allWindowSessions.count, 11)
        XCTAssertTrue(allWindowSessions.allSatisfy { $0.planActionID == planActionID })
        XCTAssertFalse(allWindowSessions.contains { $0.sessionID == boundarySessionID })
        XCTAssertTrue(try service.upcomingConfirmedSessions(in: start..<end, limit: 0).isEmpty)
        XCTAssertEqual(try service.confirmedPlans().count, 66)
    }

    func testConfirmedPlanPagesKeepAllRowsAcrossTiedTenRowBoundaries() throws {
        let (container, multiDayService, _) = try makeService()
        let singleSessionService = WorkoutPlanSchedulingService(modelContainer: container)
        let context = ModelContext(container)
        let scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
        var singleActionIDs: [UUID] = []
        var multiActionIDs: [UUID] = []

        for index in 0..<25 {
            let singleActionID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9_000 + index))!
            let singleDraft = WorkoutPlanDraft(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9_100 + index))!,
                name: "并列单日计划",
                activity: .walking,
                location: .outdoor,
                goal: .timeMinutes(30),
                scheduledAt: scheduledAt
            )
            let singleEntry = ConfirmedWorkoutPlanEntry(
                actionID: singleActionID,
                idempotencyKey: "single-page-\(index)",
                draft: singleDraft,
                state: index == 5 ? .terminal : .queued
            )
            let singleEvent = ScheduleEvent(
                date: scheduledAt,
                title: "并列单日计划",
                notes: try singleEntry.encodedNotes(),
                startTime: scheduledAt
            )
            singleEvent.createdAt = scheduledAt
            context.insert(singleEvent)
            singleActionIDs.append(singleActionID)

            let multiActionID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9_200 + index))!
            let multiDraft = TrainingPlanDraft(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9_300 + index))!,
                name: "并列多日计划",
                createdAt: scheduledAt,
                sessions: [TrainingSessionDraft(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 9_400 + index))!,
                    date: scheduledAt,
                    activity: .walking,
                    goal: .timeMinutes(30),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "保持轻松步行。"
                )]
            )
            let multiEntry = ConfirmedTrainingPlanEntry(
                actionID: multiActionID,
                idempotencyKey: "multi-page-\(index)",
                draft: multiDraft,
                state: index == 8 ? .terminal : .queued
            )
            let multiEvent = ScheduleEvent(
                date: scheduledAt,
                title: "并列多日计划",
                notes: try multiEntry.encodedNotes(),
                startTime: scheduledAt
            )
            multiEvent.createdAt = scheduledAt
            context.insert(multiEvent)
            multiActionIDs.append(multiActionID)
        }
        try context.save()

        let firstSinglePage = try singleSessionService.confirmedPlansPage(offset: 0)
        XCTAssertEqual(firstSinglePage.entries.count, ConfirmedPlanPageSizing.pageSize)
        XCTAssertEqual(firstSinglePage.nextOffset, ConfirmedPlanPageSizing.pageSize)
        XCTAssertEqual(
            firstSinglePage.entries.map(\.actionID),
            try singleSessionService.confirmedPlansPage(offset: 0).entries.map(\.actionID)
        )
        var singlePage = firstSinglePage
        var singleEntries = firstSinglePage.entries
        while let nextOffset = singlePage.nextOffset {
            singlePage = try singleSessionService.confirmedPlansPage(offset: nextOffset)
            singleEntries.append(contentsOf: singlePage.entries)
        }
        XCTAssertEqual(singleEntries.count, 25)
        XCTAssertEqual(Set(singleEntries.map(\.actionID)), Set(singleActionIDs))
        XCTAssertEqual(try singleSessionService.confirmedPlans().count, 25)

        let firstMultiPage = try multiDayService.confirmedPlansPage(offset: 0)
        XCTAssertEqual(firstMultiPage.entries.count, ConfirmedPlanPageSizing.pageSize)
        XCTAssertEqual(firstMultiPage.nextOffset, ConfirmedPlanPageSizing.pageSize)
        XCTAssertEqual(
            firstMultiPage.entries.map(\.actionID),
            try multiDayService.confirmedPlansPage(offset: 0).entries.map(\.actionID)
        )
        var multiPage = firstMultiPage
        var multiEntries = firstMultiPage.entries
        while let nextOffset = multiPage.nextOffset {
            multiPage = try multiDayService.confirmedPlansPage(offset: nextOffset)
            multiEntries.append(contentsOf: multiPage.entries)
        }
        XCTAssertEqual(multiEntries.count, 25)
        XCTAssertEqual(Set(multiEntries.map(\.actionID)), Set(multiActionIDs))
        XCTAssertEqual(try multiDayService.confirmedPlans().count, 25)
    }

    private func makeService() throws -> (ModelContainer, TrainingPlanSchedulingService, FakeMultiDayWorkoutScheduler) {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let client = FakeMultiDayWorkoutScheduler()
        return (container, TrainingPlanSchedulingService(modelContainer: container, client: client), client)
    }

    private func insertConfirmedPlan(actionID: UUID, draft: TrainingPlanDraft, in container: ModelContainer) throws {
        let entry = ConfirmedTrainingPlanEntry(
            actionID: actionID,
            idempotencyKey: "training-plan-\(actionID.uuidString.lowercased())",
            draft: draft
        )
        let start = try XCTUnwrap(draft.sessions.map(\.date).min())
        let context = ModelContext(container)
        context.insert(ScheduleEvent(date: start, title: draft.name, notes: try entry.encodedNotes(), startTime: start))
        context.insert(ScheduleEvent(
            date: start,
            title: "普通日程",
            notes: "普通日程备注",
            startTime: start.addingTimeInterval(600)
        ))
        try context.save()
    }

    private func makeDraft() -> TrainingPlanDraft {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return TrainingPlanDraft(
            name: "轻松一周",
            sessions: [
                TrainingSessionDraft(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
                    date: start,
                    activity: .walking,
                    goal: .timeMinutes(30),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "以轻松步行保持活动。"
                ),
                TrainingSessionDraft(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
                    date: start.addingTimeInterval(86_400),
                    activity: nil,
                    reason: "预留一天恢复。"
                ),
                TrainingSessionDraft(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
                    date: start.addingTimeInterval(172_800),
                    activity: .running,
                    goal: .timeMinutes(25),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "保持能交谈的轻松强度。"
                ),
            ]
        )
    }
}

private enum TrainingPlanSchedulingTestError: Error, Equatable {
    case injected
}

@MainActor
private final class FakeMultiDayWorkoutScheduler: MultiDayWorkoutSchedulingClient {
    private(set) var authorizationCount = 0
    private(set) var scheduledPlanIDs = Set<UUID>()
    private(set) var scheduledDates: [Date] = []
    var failOnCall: Int?
    private var scheduleCallCount = 0

    func authorize() async throws {
        authorizationCount += 1
    }

    func isScheduled(planID: UUID) async -> Bool {
        scheduledPlanIDs.contains(planID)
    }

    func schedule(_ plan: WorkoutPlan, at date: Date) async throws {
        scheduleCallCount += 1
        if let failOnCall, scheduleCallCount == failOnCall {
            throw TrainingPlanSchedulingTestError.injected
        }
        scheduledPlanIDs.insert(plan.id)
        scheduledDates.append(date)
    }
}
