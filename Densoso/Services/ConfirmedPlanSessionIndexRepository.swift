import Foundation
import SwiftData

enum ConfirmedPlanSessionIndexRepository {
    static func replace(
        workoutPlan entry: ConfirmedWorkoutPlanEntry,
        in context: ModelContext
    ) throws {
        try delete(actionID: entry.actionID, in: context)
        guard let scheduledAt = entry.draft.scheduledAt else { return }
        let notes = try entry.encodedNotes()
        context.insert(ConfirmedPlanSessionIndexRecord(
            actionID: entry.actionID,
            sessionID: entry.actionID,
            scheduledAt: scheduledAt,
            planKindRaw: "workout",
            stateRaw: entry.state.rawValue,
            notes: notes
        ))
    }

    static func replace(
        trainingPlan entry: ConfirmedTrainingPlanEntry,
        in context: ModelContext
    ) throws {
        try delete(actionID: entry.actionID, in: context)
        let notes = try entry.encodedNotes()
        for session in entry.draft.sessions where !session.isRestDay {
            context.insert(ConfirmedPlanSessionIndexRecord(
                actionID: entry.actionID,
                sessionID: session.id,
                scheduledAt: session.date,
                planKindRaw: "training",
                stateRaw: entry.state.rawValue,
                notes: notes
            ))
        }
    }

    static func fetchCandidates(
        from start: Date,
        through end: Date,
        limit: Int,
        in context: ModelContext
    ) throws -> [ConfirmedPlanSessionIndexRecord] {
        guard start < end, limit > 0 else { return [] }
        let terminalState = "terminal"
        let predicate = #Predicate<ConfirmedPlanSessionIndexRecord> {
            $0.scheduledAt >= start
                && $0.scheduledAt < end
                && $0.stateRaw != terminalState
        }
        var descriptor = FetchDescriptor<ConfirmedPlanSessionIndexRecord>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.scheduledAt),
                SortDescriptor(\.sessionID),
                SortDescriptor(\.actionID),
            ]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    static func rebuild(in context: ModelContext, saveChanges: Bool = true) throws {
        try context.delete(model: ConfirmedPlanSessionIndexRecord.self)
        let workoutPrefix = ConfirmedWorkoutPlanEntry.notesPrefix
        let trainingPrefix = ConfirmedTrainingPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> {
            $0.notes?.contains(workoutPrefix) == true
                || $0.notes?.contains(trainingPrefix) == true
        }
        var descriptor = FetchDescriptor<ScheduleEvent>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.date),
                SortDescriptor(\.startTime),
                SortDescriptor(\.createdAt),
                SortDescriptor(\.title),
                SortDescriptor(\.notes),
            ]
        )
        descriptor.fetchLimit = 128
        var offset = 0
        while true {
            descriptor.fetchOffset = offset
            let events = try context.fetch(descriptor)
            guard !events.isEmpty else { break }
            for event in events {
                if let entry = ConfirmedWorkoutPlanEntry.decode(notes: event.notes) {
                    try append(workoutPlan: entry, notes: event.notes ?? entry.encodedNotes(), in: context)
                } else if let entry = ConfirmedTrainingPlanEntry.decode(notes: event.notes) {
                    try append(trainingPlan: entry, notes: event.notes ?? entry.encodedNotes(), in: context)
                }
            }
            offset += events.count
            if events.count < 128 { break }
        }
        if saveChanges { try context.save() }
    }

    private static func delete(actionID: UUID, in context: ModelContext) throws {
        let predicate = #Predicate<ConfirmedPlanSessionIndexRecord> { $0.actionID == actionID }
        for record in try context.fetch(FetchDescriptor<ConfirmedPlanSessionIndexRecord>(predicate: predicate)) {
            context.delete(record)
        }
    }

    private static func append(
        workoutPlan entry: ConfirmedWorkoutPlanEntry,
        notes: String,
        in context: ModelContext
    ) throws {
        guard let scheduledAt = entry.draft.scheduledAt else { return }
        context.insert(ConfirmedPlanSessionIndexRecord(
            actionID: entry.actionID,
            sessionID: entry.actionID,
            scheduledAt: scheduledAt,
            planKindRaw: "workout",
            stateRaw: entry.state.rawValue,
            notes: notes
        ))
    }

    private static func append(
        trainingPlan entry: ConfirmedTrainingPlanEntry,
        notes: String,
        in context: ModelContext
    ) {
        for session in entry.draft.sessions where !session.isRestDay {
            context.insert(ConfirmedPlanSessionIndexRecord(
                actionID: entry.actionID,
                sessionID: session.id,
                scheduledAt: session.date,
                planKindRaw: "training",
                stateRaw: entry.state.rawValue,
                notes: notes
            ))
        }
    }
}
