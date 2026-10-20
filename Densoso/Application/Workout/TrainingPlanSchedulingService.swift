import DensosoDomain
import Foundation
import Observation
import SwiftData
import WorkoutKit

enum ConfirmedPlanPageSizing {
    static let pageSize = 10
}

struct ConfirmedPlanPage<Entry: Sendable>: Sendable {
    let entries: [Entry]
    let nextOffset: Int?
}

struct ConfirmedTrainingPlanSessionSummary: Equatable, Sendable {
    let planActionID: UUID
    let sessionID: UUID
    let planName: String
    let scheduledAt: Date
    let activity: WorkoutPlanDraft.Activity
    let state: ConfirmedTrainingPlanEntry.State
    let lastError: String?
}

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
    private static let confirmedPlanFetchBatchSize = 64

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
        return try fetchConfirmedPlanEvents(in: context)
            .compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) }
            .sorted { lhs, rhs in
                if lhs.draft.createdAt != rhs.draft.createdAt {
                    return lhs.draft.createdAt > rhs.draft.createdAt
                }
                return lhs.draft.id.uuidString < rhs.draft.id.uuidString
            }
    }

    func confirmedPlansPage(offset: Int) throws -> ConfirmedPlanPage<ConfirmedTrainingPlanEntry> {
        let pageOffset = max(offset, 0)
        let context = ModelContext(modelContainer)
        let prefix = ConfirmedTrainingPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> { $0.notes?.contains(prefix) == true }
        let sortDescriptors: [SortDescriptor<ScheduleEvent>] = [
            SortDescriptor(\ScheduleEvent.createdAt, order: .reverse),
            SortDescriptor(\ScheduleEvent.date, order: .reverse),
            SortDescriptor(\ScheduleEvent.startTime, order: .reverse),
            SortDescriptor(\ScheduleEvent.title),
            SortDescriptor(\ScheduleEvent.notes),
        ]
        var descriptor = FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)
        descriptor.fetchOffset = pageOffset
        descriptor.fetchLimit = ConfirmedPlanPageSizing.pageSize + 1
        let events = try context.fetch(descriptor)
        let pageEvents = Array(events.prefix(ConfirmedPlanPageSizing.pageSize))
        let nextOffset = events.count > ConfirmedPlanPageSizing.pageSize
            ? pageOffset + ConfirmedPlanPageSizing.pageSize
            : nil
        return ConfirmedPlanPage(
            entries: pageEvents.compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) },
            nextOffset: nextOffset
        )
    }

    func upcomingConfirmedSessions(
        in dateRange: Range<Date>,
        limit: Int
    ) throws -> [ConfirmedTrainingPlanSessionSummary] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0, dateRange.lowerBound < dateRange.upperBound else { return [] }

        let context = ModelContext(modelContainer)
        let prefix = ConfirmedTrainingPlanEntry.notesPrefix
        let rangeEnd = dateRange.upperBound
        let sortDescriptors: [SortDescriptor<ScheduleEvent>] = [
            SortDescriptor(\ScheduleEvent.date),
            SortDescriptor(\ScheduleEvent.startTime),
            SortDescriptor(\ScheduleEvent.createdAt),
            SortDescriptor(\ScheduleEvent.title),
            SortDescriptor(\ScheduleEvent.notes),
        ]
        // The event date is the plan's earliest session, so older plans may still contribute sessions.
        let predicate = #Predicate<ScheduleEvent> {
            $0.date < rangeEnd && $0.notes?.contains(prefix) == true
        }
        var descriptor = FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)
        descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize

        var offset = 0
        var summaries: [ConfirmedTrainingPlanSessionSummary] = []
        var cutoffDate: Date?

        while true {
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            guard !page.isEmpty else { break }

            var passedCutoffDate = false
            for event in page {
                // Confirmed plan events are stored at the plan's earliest session date.
                if let cutoffDate, event.date > cutoffDate {
                    passedCutoffDate = true
                    break
                }
                guard let entry = ConfirmedTrainingPlanEntry.decode(notes: event.notes),
                      entry.state != .terminal else { continue }
                for session in entry.draft.sessions {
                    guard dateRange.contains(session.date),
                          let activity = session.activity else { continue }
                    summaries.append(ConfirmedTrainingPlanSessionSummary(
                        planActionID: entry.actionID,
                        sessionID: session.id,
                        planName: entry.draft.name,
                        scheduledAt: session.date,
                        activity: activity,
                        state: entry.state,
                        lastError: entry.lastError
                    ))
                }
                summaries.sort(by: Self.confirmedSessionOrder)
                if summaries.count > boundedLimit {
                    summaries.removeLast(summaries.count - boundedLimit)
                }
                if summaries.count == boundedLimit {
                    cutoffDate = summaries.last?.scheduledAt
                }
            }

            if passedCutoffDate { break }
            offset += page.count
            if page.count < Self.confirmedPlanFetchBatchSize { break }
        }

        return summaries
    }

    private static func confirmedSessionOrder(
        _ lhs: ConfirmedTrainingPlanSessionSummary,
        _ rhs: ConfirmedTrainingPlanSessionSummary
    ) -> Bool {
        if lhs.scheduledAt != rhs.scheduledAt { return lhs.scheduledAt < rhs.scheduledAt }
        if lhs.sessionID != rhs.sessionID {
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
        return lhs.planActionID.uuidString < rhs.planActionID.uuidString
    }

    private func fetchConfirmedPlanEvents(in context: ModelContext) throws -> [ScheduleEvent] {
        let prefix = ConfirmedTrainingPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> { $0.notes?.contains(prefix) == true }
        let sortDescriptors: [SortDescriptor<ScheduleEvent>] = [
            SortDescriptor(\ScheduleEvent.date),
            SortDescriptor(\ScheduleEvent.startTime),
            SortDescriptor(\ScheduleEvent.createdAt),
            SortDescriptor(\ScheduleEvent.title),
            SortDescriptor(\ScheduleEvent.notes),
        ]
        var descriptor = FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)
        descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize

        var offset = 0
        var events: [ScheduleEvent] = []
        while true {
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            guard !page.isEmpty else { break }
            events.append(contentsOf: page)
            offset += page.count
            if page.count < Self.confirmedPlanFetchBatchSize { break }
        }
        return events
    }

    private func scheduleConfirmedPlanOnce(actionID: UUID) async throws {
        let context = ModelContext(modelContainer)
        let events = try fetchConfirmedPlanEvents(in: context)
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
            entry.lastError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .workoutKitUnavailableFallback
            ).userMessage
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
            entry.lastError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .workoutKitUnavailableFallback
            ).userMessage
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
