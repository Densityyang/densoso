import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class WorkoutPlanSchedulingServiceTests: XCTestCase {
    func testUnconfirmedPlanNeverCallsWorkoutScheduler() async throws {
        let (container, service, client) = try makeService()

        do {
            try await service.scheduleConfirmedPlan(actionID: UUID())
            XCTFail("Expected no confirmed plan to be found")
        } catch {
            XCTAssertEqual(error as? WorkoutPlanCompileError, .confirmedPlanNotFound)
        }
        XCTAssertEqual(client.callCount, 0)
        _ = container
    }

    func testConfirmedScheduleIsIdempotentAcrossRetries() async throws {
        let (container, service, client) = try makeService()
        let actionID = UUID()
        try insertConfirmedPlan(actionID: actionID, in: container)

        XCTAssertEqual(try service.confirmedPlans().map(\.actionID), [actionID])
        try await service.scheduleConfirmedPlan(actionID: actionID)
        try await service.scheduleConfirmedPlan(actionID: actionID)

        XCTAssertEqual(client.callCount, 1)
        let entry = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }
                .first
        )
        XCTAssertEqual(entry.state, .scheduled)
    }

    func testConfirmedSinglePlanHistoryPagesAcross64EventBoundary() async throws {
        let (container, service, client) = try makeService()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var actionIDs: [UUID] = []

        for index in 0..<65 {
            let actionID = UUID()
            let scheduledAt = start.addingTimeInterval(TimeInterval(index))
            let draft = WorkoutPlanDraft(
                id: actionID,
                name: "已确认步行 \(index)",
                activity: .walking,
                location: .outdoor,
                goal: .timeMinutes(30),
                scheduledAt: scheduledAt
            )
            let entry = ConfirmedWorkoutPlanEntry(
                actionID: actionID,
                idempotencyKey: "confirmed-\(actionID.uuidString.lowercased())",
                draft: draft
            )
            context.insert(ScheduleEvent(
                date: scheduledAt,
                title: draft.name,
                notes: try entry.encodedNotes(),
                startTime: scheduledAt
            ))
            actionIDs.append(actionID)
        }
        context.insert(ScheduleEvent(date: start, title: "普通日程", notes: "普通备注", startTime: start))
        try context.save()

        let confirmed = try service.confirmedPlans()
        XCTAssertEqual(confirmed.count, 65)
        XCTAssertEqual(confirmed.map(\.actionID), Array(actionIDs.reversed()))

        let targetActionID = try XCTUnwrap(actionIDs.last)
        try await service.scheduleConfirmedPlan(actionID: targetActionID)
        XCTAssertEqual(client.scheduledActionIDs, [targetActionID])
    }

    func testConfirmedMultiDayPlanKeepsPriorityForSharedActionID() async throws {
        let (container, service, client) = try makeService()
        let actionID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let singleDraft = WorkoutPlanDraft(
            id: actionID,
            name: "单日计划",
            activity: .walking,
            location: .outdoor,
            goal: .timeMinutes(30),
            scheduledAt: date
        )
        let singleEntry = ConfirmedWorkoutPlanEntry(
            actionID: actionID,
            idempotencyKey: "single-\(actionID.uuidString.lowercased())",
            draft: singleDraft
        )
        let trainingDraft = TrainingPlanDraft(
            name: "多日计划",
            createdAt: date,
            sessions: [TrainingSessionDraft(date: date, activity: nil, reason: "恢复日。")]
        )
        let trainingEntry = ConfirmedTrainingPlanEntry(
            actionID: actionID,
            idempotencyKey: "multi-\(actionID.uuidString.lowercased())",
            draft: trainingDraft
        )
        let context = ModelContext(container)
        let singleEvent = ScheduleEvent(
            date: date,
            title: singleDraft.name,
            notes: try singleEntry.encodedNotes(),
            startTime: date
        )
        singleEvent.createdAt = date
        let trainingEvent = ScheduleEvent(
            date: date,
            title: trainingDraft.name,
            notes: try trainingEntry.encodedNotes(),
            startTime: date
        )
        trainingEvent.createdAt = date.addingTimeInterval(1)
        context.insert(singleEvent)
        context.insert(trainingEvent)
        try context.save()

        try await service.scheduleConfirmedPlan(actionID: actionID)

        XCTAssertEqual(client.callCount, 0)
        let verificationContext = ModelContext(container)
        let storedPlans = try verificationContext.fetch(FetchDescriptor<ScheduleEvent>())
        let storedSingle = try XCTUnwrap(
            storedPlans.compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }.first
        )
        let storedTraining = try XCTUnwrap(
            storedPlans.compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) }.first
        )
        XCTAssertEqual(storedSingle.state, .queued)
        XCTAssertEqual(storedTraining.state, .scheduled)
    }

    func testConcurrentScheduleRequestsForOneConfirmedPlanAreCoalesced() async throws {
        let (container, service, client) = try makeService()
        let actionID = UUID()
        try insertConfirmedPlan(actionID: actionID, in: container)
        client.delayNanoseconds = 100_000_000

        let first = Task { try await service.scheduleConfirmedPlan(actionID: actionID) }
        await Task.yield()
        try await service.scheduleConfirmedPlan(actionID: actionID)
        try await first.value

        XCTAssertEqual(client.callCount, 1)
        let entry = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }
                .first
        )
        XCTAssertEqual(entry.state, .scheduled)
    }

    func testConcurrentScheduleWaitersReceiveTheSameFailure() async throws {
        let (container, service, client) = try makeService()
        let actionID = UUID()
        try insertConfirmedPlan(actionID: actionID, in: container)
        client.delayNanoseconds = 100_000_000
        client.failNext = true

        let first = Task { try await service.scheduleConfirmedPlan(actionID: actionID) }
        await Task.yield()
        do {
            try await service.scheduleConfirmedPlan(actionID: actionID)
            XCTFail("Concurrent waiter should receive the scheduling failure")
        } catch {
            XCTAssertEqual(error as? TestSchedulingError, .injected)
        }
        do {
            try await first.value
            XCTFail("First schedule should fail")
        } catch {
            XCTAssertEqual(error as? TestSchedulingError, .injected)
        }

        XCTAssertEqual(client.callCount, 1)
        let entry = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }
                .first
        )
        XCTAssertEqual(entry.state, .retryable)
    }

    func testTransientWorkoutKitFailureLeavesAUserRetryableScheduleIntent() async throws {
        let (container, service, client) = try makeService()
        let actionID = UUID()
        try insertConfirmedPlan(actionID: actionID, in: container)
        client.failNext = true

        do {
            try await service.scheduleConfirmedPlan(actionID: actionID)
            XCTFail("Expected the injected scheduling error")
        } catch {
            XCTAssertEqual(error as? TestSchedulingError, .injected)
        }
        let firstState = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }
                .first?.state
        )
        XCTAssertEqual(firstState, .retryable)

        try await service.scheduleConfirmedPlan(actionID: actionID)
        XCTAssertEqual(client.callCount, 2)
        let finalState = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ScheduleEvent>())
                .compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }
                .first?.state
        )
        XCTAssertEqual(finalState, .scheduled)
    }

    private func makeService() throws -> (ModelContainer, WorkoutPlanSchedulingService, FakeWorkoutPlanScheduler) {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let client = FakeWorkoutPlanScheduler()
        return (container, WorkoutPlanSchedulingService(modelContainer: container, client: client), client)
    }

    private func insertConfirmedPlan(actionID: UUID, in container: ModelContainer) throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = WorkoutPlanDraft(
            id: actionID,
            name: "已确认步行",
            activity: .walking,
            location: .outdoor,
            goal: .timeMinutes(30),
            scheduledAt: start
        )
        let entry = ConfirmedWorkoutPlanEntry(
            actionID: actionID,
            idempotencyKey: "confirmed-\(actionID.uuidString.lowercased())",
            draft: draft
        )
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
}

private enum TestSchedulingError: Error, Equatable {
    case injected
}

@MainActor
private final class FakeWorkoutPlanScheduler: WorkoutPlanSchedulingClient {
    var callCount = 0
    private(set) var scheduledActionIDs: [UUID] = []
    var failNext = false
    var delayNanoseconds: UInt64 = 0

    func scheduleConfirmed(_ draft: WorkoutPlanDraft) async throws {
        callCount += 1
        scheduledActionIDs.append(draft.id)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if failNext {
            failNext = false
            throw TestSchedulingError.injected
        }
    }
}
