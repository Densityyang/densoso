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
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
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
        try context.save()
    }
}

private enum TestSchedulingError: Error, Equatable {
    case injected
}

@MainActor
private final class FakeWorkoutPlanScheduler: WorkoutPlanSchedulingClient {
    var callCount = 0
    var failNext = false
    var delayNanoseconds: UInt64 = 0

    func scheduleConfirmed(_ draft: WorkoutPlanDraft) async throws {
        callCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if failNext {
            failNext = false
            throw TestSchedulingError.injected
        }
    }
}
