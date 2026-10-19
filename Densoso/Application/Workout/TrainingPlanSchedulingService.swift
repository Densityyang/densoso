import DensosoDomain
import Foundation
import Observation
import SwiftData
import WorkoutKit

@MainActor
protocol MultiDayWorkoutSchedulingClient {
    func authorize() async throws
    func isScheduled(planID: UUID) async -> Bool
    func schedule(_ plan: WorkoutPlan, at date: Date) async throws
}

@concurrent
private func multiDayWorkoutPlanIsAlreadyScheduled(_ planID: UUID) async -> Bool {
    let scheduler = WorkoutScheduler.shared
    let scheduledWorkouts = await scheduler.scheduledWorkouts
    return scheduledWorkouts.contains { $0.plan.id == planID }
}

@MainActor
struct WorkoutKitMultiDaySchedulingClient: MultiDayWorkoutSchedulingClient {
    func authorize() async throws {
        guard WorkoutScheduler.isSupported else {
            throw WorkoutPlanCompileError.schedulingUnavailable
        }
        guard await WorkoutScheduler.shared.requestAuthorization() == .authorized else {
            throw WorkoutPlanCompileError.scheduleAuthorizationDenied
        }
    }

    func isScheduled(planID: UUID) async -> Bool {
        await multiDayWorkoutPlanIsAlreadyScheduled(planID)
    }

    func schedule(_ plan: WorkoutPlan, at date: Date) async throws {
        let components = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: date
        )
        await WorkoutScheduler.shared.schedule(plan, at: components)
    }
}

/// Schedules each confirmed workout day independently. Rest days remain in the
/// persisted training plan, and a retry skips session IDs already known to
/// WorkoutKit so partial progress can safely resume.
@MainActor
@Observable
final class TrainingPlanSchedulingService {
    private let modelContainer: ModelContainer
    private let client: any MultiDayWorkoutSchedulingClient
    private let compiler = TrainingPlanCompiler()
    private var schedulingActionIDs = Set<UUID>()
    private var schedulingWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]

    init(
        modelContainer: ModelContainer,
        client: any MultiDayWorkoutSchedulingClient = WorkoutKitMultiDaySchedulingClient()
    ) {
        self.modelContainer = modelContainer
        self.client = client
    }

    func scheduleConfirmedPlan(actionID: UUID) async throws {
        if schedulingActionIDs.contains(actionID) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                schedulingWaiters[actionID, default: []].append(continuation)
            }
            return
        }
        schedulingActionIDs.insert(actionID)

        do {
            try await scheduleConfirmedPlanOnce(actionID: actionID)
            finishScheduling(actionID: actionID, result: .success(()))
        } catch {
            finishScheduling(actionID: actionID, result: .failure(error))
            throw error
        }
    }

    func confirmedPlans() throws -> [ConfirmedTrainingPlanEntry] {
        let context = ModelContext(modelContainer)
        let prefix = ConfirmedTrainingPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> { ($0.notes ?? "").contains(prefix) }
        return try context.fetch(FetchDescriptor<ScheduleEvent>(predicate: predicate))
            .compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) }
            .sorted { lhs, rhs in
                if lhs.draft.createdAt != rhs.draft.createdAt {
                    return lhs.draft.createdAt > rhs.draft.createdAt
                }
                return lhs.draft.id.uuidString < rhs.draft.id.uuidString
            }
    }

    private func scheduleConfirmedPlanOnce(actionID: UUID) async throws {
        let context = ModelContext(modelContainer)
        let prefix = ConfirmedTrainingPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> { ($0.notes ?? "").contains(prefix) }
        let events = try context.fetch(FetchDescriptor<ScheduleEvent>(predicate: predicate))
        guard let event = events.first(where: {
            ConfirmedTrainingPlanEntry.decode(notes: $0.notes)?.actionID == actionID
        }), var entry = ConfirmedTrainingPlanEntry.decode(notes: event.notes) else {
            throw WorkoutPlanCompileError.confirmedPlanNotFound
        }
        if entry.state == .scheduled { return }

        let compiled: CompiledTrainingPlan
        do {
            compiled = try compiler.compile(entry.draft)
        } catch {
            entry.state = .terminal
            entry.lastError = String(error.localizedDescription.prefix(500))
            event.notes = try entry.encodedNotes()
            try context.save()
            throw error
        }

        do {
            if !compiled.workoutSessions.isEmpty {
                try await client.authorize()
            }

            for session in compiled.workoutSessions {
                guard let workoutPlan = session.workoutPlan else { continue }
                let alreadyScheduled: Bool
                if entry.scheduledSessionIDs.contains(session.id) {
                    alreadyScheduled = true
                } else {
                    alreadyScheduled = await client.isScheduled(planID: workoutPlan.id)
                }
                if !alreadyScheduled {
                    try await client.schedule(workoutPlan, at: session.draft.date)
                }
                if !entry.scheduledSessionIDs.contains(session.id) {
                    entry.scheduledSessionIDs.append(session.id)
                    entry.scheduledSessionIDs.sort { $0.uuidString < $1.uuidString }
                }
                entry.lastError = nil
                event.notes = try entry.encodedNotes()
                try context.save()
            }

            entry.state = .scheduled
            entry.lastError = nil
            event.notes = try entry.encodedNotes()
            try context.save()
        } catch {
            entry.state = .retryable
            entry.lastError = String(error.localizedDescription.prefix(500))
            event.notes = try entry.encodedNotes()
            try? context.save()
            throw error
        }
    }

    private func finishScheduling(actionID: UUID, result: Result<Void, Error>) {
        schedulingActionIDs.remove(actionID)
        let waiters = schedulingWaiters.removeValue(forKey: actionID) ?? []
        for waiter in waiters { waiter.resume(with: result) }
    }
}
