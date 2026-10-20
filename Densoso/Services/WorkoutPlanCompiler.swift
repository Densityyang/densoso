import Foundation
import HealthKit
import Observation
import SwiftData
import WorkoutKit
import DensosoDomain

enum WorkoutPlanCompileError: Equatable, SharedErrorDescribing {
    case emptyName
    case invalidTimeGoal
    case invalidDistanceGoal
    case invalidLegacyStrengthData
    case unsupportedActivity
    case unsupportedGoal
    case scheduleDateRequired
    case scheduleAuthorizationDenied
    case schedulingUnavailable
    case confirmedPlanNotFound

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .scheduleAuthorizationDenied:
            SharedErrorDescriptor(
                code: .workoutKitUnauthorized,
                userMessage: "未获得将训练计划同步到 Apple Watch 的授权。",
                subsystem: .workoutKit,
                reason: .workoutKitAuthorizationDenied
            )
        case .schedulingUnavailable:
            SharedErrorDescriptor(
                code: .watchUnavailable,
                userMessage: "Apple Watch 暂不支持训练计划同步。",
                subsystem: .workoutKit,
                reason: .workoutKitUnavailable
            )
        case .confirmedPlanNotFound:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "找不到已确认的训练计划，请重新检查。",
                subsystem: .workoutKit,
                reason: .workoutPlanConflict
            )
        case .emptyName, .invalidTimeGoal, .invalidDistanceGoal, .invalidLegacyStrengthData,
             .unsupportedActivity, .unsupportedGoal, .scheduleDateRequired:
            SharedErrorDescriptor(
                code: .toolArgumentsInvalid,
                userMessage: "训练计划暂时无法安排，请检查计划内容后重试。",
                subsystem: .workoutKit,
                reason: .invalidWorkoutPlan
            )
        }
    }

    var errorDescription: String? { sharedErrorDescriptor.userMessage }
}

@concurrent
private func workoutPlanIsAlreadyScheduled(_ planID: UUID) async -> Bool {
    let scheduler = WorkoutScheduler.shared
    let scheduledWorkouts = await scheduler.scheduledWorkouts
    return scheduledWorkouts.contains { $0.plan.id == planID }
}

/// Validates and compiles a user-confirmed single-goal draft into WorkoutKit.
/// Legacy set fields are rejected and are never passed to Apple's scheduler.
struct WorkoutPlanCompiler {
    func validate(_ draft: WorkoutPlanDraft) throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkoutPlanCompileError.emptyName
        }
        guard draft.activity.isWorkoutKitSupported else {
            throw WorkoutPlanCompileError.unsupportedActivity
        }
        guard draft.strengthSets.isEmpty else {
            throw WorkoutPlanCompileError.invalidLegacyStrengthData
        }
        guard draft.scheduledAt != nil else {
            throw WorkoutPlanCompileError.scheduleDateRequired
        }

        switch draft.goal {
        case .open:
            break
        case .timeMinutes(let minutes):
            guard (1...720).contains(minutes) else { throw WorkoutPlanCompileError.invalidTimeGoal }
        case .distanceMeters(let meters):
            guard meters.isFinite, (100...100_000).contains(meters) else {
                throw WorkoutPlanCompileError.invalidDistanceGoal
            }
        }
    }

    func compile(_ draft: WorkoutPlanDraft) throws -> WorkoutPlan {
        try validate(draft)

        let activity = healthKitActivity(for: draft.activity)
        let location = healthKitLocation(for: draft.location)
        let goal = workoutGoal(for: draft.goal)

        guard SingleGoalWorkout.supportsActivity(activity) else {
            throw WorkoutPlanCompileError.unsupportedActivity
        }
        guard SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) else {
            throw WorkoutPlanCompileError.unsupportedGoal
        }

        let workout = SingleGoalWorkout(activity: activity, location: location, goal: goal)
        return WorkoutPlan(.goal(workout), id: draft.id)
    }

    private func healthKitActivity(for activity: WorkoutPlanDraft.Activity) -> HKWorkoutActivityType {
        switch activity {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .swimming: .swimming
        case .hiking: .hiking
        case .strength: .traditionalStrengthTraining
        case .hiit: .highIntensityIntervalTraining
        }
    }

    private func healthKitLocation(for location: WorkoutPlanDraft.Location) -> HKWorkoutSessionLocationType {
        location == .indoor ? .indoor : .outdoor
    }

    private func workoutGoal(for goal: WorkoutPlanDraft.Goal) -> WorkoutGoal {
        switch goal {
        case .open: .open
        case .timeMinutes(let minutes): .time(Double(minutes), .minutes)
        case .distanceMeters(let meters): .distance(meters, .meters)
        }
    }
}

@MainActor
protocol WorkoutPlanSchedulingClient {
    func scheduleConfirmed(_ draft: WorkoutPlanDraft) async throws
}

@MainActor
struct WorkoutKitPlanSchedulingClient: WorkoutPlanSchedulingClient {
    private let compiler = WorkoutPlanCompiler()

    func scheduleConfirmed(_ draft: WorkoutPlanDraft) async throws {
        try compiler.validate(draft)
        guard let scheduledAt = draft.scheduledAt else { throw WorkoutPlanCompileError.scheduleDateRequired }
        guard WorkoutScheduler.isSupported else { throw WorkoutPlanCompileError.schedulingUnavailable }

        let plan = try compiler.compile(draft)
        let scheduler = WorkoutScheduler.shared
        guard await scheduler.requestAuthorization() == .authorized else {
            throw WorkoutPlanCompileError.scheduleAuthorizationDenied
        }
        let alreadyScheduled = await workoutPlanIsAlreadyScheduled(plan.id)
        guard !alreadyScheduled else { return }
        await scheduler.schedule(plan, at: Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: scheduledAt
        ))
    }
}

@MainActor
@Observable
final class WorkoutPlanSchedulingService {
    private static let confirmedPlanFetchBatchSize = 64

    private let modelContainer: ModelContainer
    private let client: any WorkoutPlanSchedulingClient
    private let multiDayService: TrainingPlanSchedulingService
    private var schedulingActionIDs = Set<UUID>()
    private var schedulingWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private(set) var lastError: String?

    init(
        modelContainer: ModelContainer,
        client: any WorkoutPlanSchedulingClient = WorkoutKitPlanSchedulingClient(),
        multiDayClient: any MultiDayWorkoutSchedulingClient = WorkoutKitMultiDaySchedulingClient()
    ) {
        self.modelContainer = modelContainer
        self.client = client
        self.multiDayService = TrainingPlanSchedulingService(
            modelContainer: modelContainer,
            client: multiDayClient
        )
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

    private func scheduleConfirmedPlanOnce(actionID: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let match = try findConfirmedPlanEvent(actionID: actionID, in: context) else {
            throw WorkoutPlanCompileError.confirmedPlanNotFound
        }
        if match.isTrainingPlan {
            do {
                try await multiDayService.scheduleConfirmedPlan(actionID: actionID)
                lastError = nil
            } catch {
                lastError = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: .workoutKitUnavailableFallback
                ).userMessage
                throw error
            }
            return
        }
        let event = match.event
        guard var entry = ConfirmedWorkoutPlanEntry.decode(notes: event.notes) else {
            throw WorkoutPlanCompileError.confirmedPlanNotFound
        }
        guard entry.state != .scheduled else { return }

        do {
            try WorkoutPlanCompiler().validate(entry.draft)
        } catch {
            entry.state = .terminal
            entry.lastError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .workoutKitUnavailableFallback
            ).userMessage
            event.notes = try entry.encodedNotes()
            try context.save()
            lastError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .workoutKitUnavailableFallback
            ).userMessage
            throw error
        }

        do {
            try await client.scheduleConfirmed(entry.draft)
            entry.state = .scheduled
            entry.lastError = nil
            event.notes = try entry.encodedNotes()
            try context.save()
            lastError = nil
        } catch {
            entry.state = .retryable
            entry.lastError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .workoutKitUnavailableFallback
            ).userMessage
            event.notes = try entry.encodedNotes()
            try context.save()
            lastError = SharedErrorDescriptor.mapped(
                from: error,
                fallback: .workoutKitUnavailableFallback
            ).userMessage
            throw error
        }
    }

    private func finishScheduling(actionID: UUID, result: Result<Void, Error>) {
        schedulingActionIDs.remove(actionID)
        let waiters = schedulingWaiters.removeValue(forKey: actionID) ?? []
        for waiter in waiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    func confirmedPlans() throws -> [ConfirmedWorkoutPlanEntry] {
        let context = ModelContext(modelContainer)
        let prefix = ConfirmedWorkoutPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> { $0.notes?.contains(prefix) == true }
        return try fetchConfirmedPlanEvents(in: context, predicate: predicate)
            .compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }
            .sorted { ($0.draft.scheduledAt ?? .distantPast) > ($1.draft.scheduledAt ?? .distantPast) }
    }

    func confirmedPlansPage(offset: Int) throws -> ConfirmedPlanPage<ConfirmedWorkoutPlanEntry> {
        let pageOffset = max(offset, 0)
        let context = ModelContext(modelContainer)
        let prefix = ConfirmedWorkoutPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> { $0.notes?.contains(prefix) == true }
        let sortDescriptors: [SortDescriptor<ScheduleEvent>] = [
            SortDescriptor(\ScheduleEvent.date, order: .reverse),
            SortDescriptor(\ScheduleEvent.startTime, order: .reverse),
            SortDescriptor(\ScheduleEvent.createdAt, order: .reverse),
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
            entries: pageEvents.compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) },
            nextOffset: nextOffset
        )
    }

    func upcomingConfirmedPlans(from startDate: Date, limit: Int) throws -> [ConfirmedWorkoutPlanEntry] {
        let boundedLimit = max(limit, 0)
        guard boundedLimit > 0 else { return [] }

        let context = ModelContext(modelContainer)
        let prefix = ConfirmedWorkoutPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> {
            $0.date >= startDate && $0.notes?.contains(prefix) == true
        }
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
        var cutoffDate: Date?
        var entries: [ConfirmedWorkoutPlanEntry] = []
        while true {
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            guard !page.isEmpty else { break }
            var passedCutoffDate = false
            for event in page {
                if let cutoffDate, event.date > cutoffDate {
                    passedCutoffDate = true
                    break
                }
                guard let entry = ConfirmedWorkoutPlanEntry.decode(notes: event.notes),
                      entry.state != .terminal,
                      let scheduledAt = entry.draft.scheduledAt,
                      scheduledAt >= startDate else { continue }
                entries.append(entry)
                if entries.count == boundedLimit, cutoffDate == nil {
                    cutoffDate = event.date
                }
            }
            if passedCutoffDate { break }
            offset += page.count
            if page.count < Self.confirmedPlanFetchBatchSize { break }
        }

        let ordered = entries.sorted { lhs, rhs in
            let leftDate = lhs.draft.scheduledAt ?? .distantPast
            let rightDate = rhs.draft.scheduledAt ?? .distantPast
            return leftDate == rightDate
                ? lhs.actionID.uuidString < rhs.actionID.uuidString
                : leftDate < rightDate
        }
        return Array(ordered.prefix(boundedLimit))
    }

    func confirmedTrainingPlans() throws -> [ConfirmedTrainingPlanEntry] {
        try multiDayService.confirmedPlans()
    }

    func confirmedTrainingPlansPage(offset: Int) throws -> ConfirmedPlanPage<ConfirmedTrainingPlanEntry> {
        try multiDayService.confirmedPlansPage(offset: offset)
    }

    func upcomingConfirmedTrainingSessions(
        in dateRange: Range<Date>,
        limit: Int
    ) throws -> [ConfirmedTrainingPlanSessionSummary] {
        try multiDayService.upcomingConfirmedSessions(in: dateRange, limit: limit)
    }

    private func confirmedPlanEventDescriptor() -> FetchDescriptor<ScheduleEvent> {
        let singlePlanPrefix = ConfirmedWorkoutPlanEntry.notesPrefix
        let multiPlanPrefix = ConfirmedTrainingPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> {
            $0.notes?.contains(singlePlanPrefix) == true
                || $0.notes?.contains(multiPlanPrefix) == true
        }
        let sortDescriptors: [SortDescriptor<ScheduleEvent>] = [
            SortDescriptor(\ScheduleEvent.date),
            SortDescriptor(\ScheduleEvent.startTime),
            SortDescriptor(\ScheduleEvent.createdAt),
            SortDescriptor(\ScheduleEvent.title),
            SortDescriptor(\ScheduleEvent.notes),
        ]
        var descriptor = FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)
        descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize
        return descriptor
    }

    private func fetchConfirmedPlanEvents(
        in context: ModelContext,
        predicate: Predicate<ScheduleEvent>
    ) throws -> [ScheduleEvent] {
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

    private func findConfirmedPlanEvent(
        actionID: UUID,
        in context: ModelContext
    ) throws -> (event: ScheduleEvent, isTrainingPlan: Bool)? {
        var descriptor = confirmedPlanEventDescriptor()
        var offset = 0
        var singlePlanMatch: ScheduleEvent?
        while true {
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            guard !page.isEmpty else { break }
            for event in page {
                if ConfirmedTrainingPlanEntry.decode(notes: event.notes)?.actionID == actionID {
                    return (event, true)
                }
                if singlePlanMatch == nil,
                   ConfirmedWorkoutPlanEntry.decode(notes: event.notes)?.actionID == actionID {
                    singlePlanMatch = event
                }
            }
            offset += page.count
            if page.count < Self.confirmedPlanFetchBatchSize { break }
        }
        return singlePlanMatch.map { ($0, false) }
    }
}
