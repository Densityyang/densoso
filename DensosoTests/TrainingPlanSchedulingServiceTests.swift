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
