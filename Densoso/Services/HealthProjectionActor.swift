import CryptoKit
import DensosoDomain
import Foundation
import SwiftData

/// Performs bounded reads and explicit deterministic projection refreshes on
/// the SwiftData model actor executor. Read-only Agent queries do not refresh or write caches.
@ModelActor
actor HealthProjectionActor {
    private var calendar: Calendar = .current

    init(modelContainer: ModelContainer, calendar: Calendar = .current) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.calendar = calendar
    }

    func refresh(asOf date: Date = Date()) throws -> HealthIntelligenceRefreshSnapshot {
        let reader = HealthIntelligenceReadModel(calendar: calendar)
        let days = try reader.loadDays(through: date, in: modelContext)
        let goal = try reader.goalProfile(asOf: date, in: modelContext)
        let plannedWorkout = try reader.plannedWorkoutTomorrow(asOf: date, in: modelContext)
        guard let result = HealthIntelligenceEngine(calendar: calendar).makeDailyBrief(
            days: days,
            goals: goal,
            plannedWorkoutTomorrow: plannedWorkout
        ) else {
            return HealthIntelligenceRefreshSnapshot(
                dailyBrief: nil,
                weeklyBrief: nil,
                updatesWeeklyBrief: false
            )
        }

        let dailySnapshotHash = try hash(
            days: days,
            goal: goal,
            algorithmVersion: result.dailyBrief.algorithmVersion,
            plannedWorkoutTomorrow: plannedWorkout
        )
        let daily = try cachedDailyBrief(
            result.dailyBrief,
            snapshotHash: dailySnapshotHash,
            in: modelContext
        )

        let weekStart = previousWeekStart(containing: date)
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let weekly = engine.makeWeeklyBrief(days: days, weekStart: weekStart, goals: goal)
        let weeklyWindowStart = calendar.date(byAdding: .day, value: -28, to: weekStart) ?? weekStart
        let weeklyWindowEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        let weeklySnapshotHash = try hash(
            days: days.filter {
                let day = calendar.startOfDay(for: $0.dayStart)
                return day >= weeklyWindowStart && day < weeklyWindowEnd
            },
            goal: goal,
            algorithmVersion: weekly.algorithmVersion
        )
        let cachedWeekly = try cachedWeeklyBrief(
            weekly,
            snapshotHash: weeklySnapshotHash,
            in: modelContext
        )
        return HealthIntelligenceRefreshSnapshot(
            dailyBrief: daily,
            weeklyBrief: cachedWeekly,
            updatesWeeklyBrief: true
        )
    }

    func loadCachedBriefs() -> HealthIntelligenceCachedBriefs {
        let decoder = makeDecoder()
        var dailyDescriptor = FetchDescriptor<DailyBriefRecord>(
            sortBy: [SortDescriptor(\DailyBriefRecord.generatedAt, order: .reverse)]
        )
        dailyDescriptor.fetchLimit = 1
        var weeklyDescriptor = FetchDescriptor<WeeklyBriefRecord>(
            sortBy: [SortDescriptor(\WeeklyBriefRecord.generatedAt, order: .reverse)]
        )
        weeklyDescriptor.fetchLimit = 1
        let dailyRecord = try? modelContext.fetch(dailyDescriptor).first
        let weeklyRecord = try? modelContext.fetch(weeklyDescriptor).first
        return HealthIntelligenceCachedBriefs(
            hasDailyRecord: dailyRecord != nil,
            dailyBrief: dailyRecord.flatMap { try? decoder.decode(DailyHealthBrief.self, from: $0.payloadData) },
            hasWeeklyRecord: weeklyRecord != nil,
            weeklyBrief: weeklyRecord.flatMap { try? decoder.decode(WeeklyHealthBrief.self, from: $0.payloadData) }
        )
    }

    func todayHealthState(asOf date: Date = Date()) throws -> HealthStateV2? {
        try HealthIntelligenceReadModel(calendar: calendar)
            .todayHealthState(asOf: date, in: modelContext)
    }

    func healthHistory(from startDate: Date, through endDate: Date) throws -> [HealthStateHistoryPoint] {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthHistory(from: startDate, through: endDate, in: modelContext)
    }

    func healthNarrativeContext(asOf date: Date = Date()) throws -> HealthNarrativeContext {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthNarrativeContext(asOf: date, in: modelContext)
    }

    func healthContextSummary(asOf date: Date = Date()) throws -> HealthContextSummary? {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthContextSummary(asOf: date, in: modelContext)
    }

    func goalProfile(asOf date: Date = Date()) throws -> GoalProfile? {
        try HealthIntelligenceReadModel(calendar: calendar).goalProfile(asOf: date, in: modelContext)
    }

    func saveGoalProfile(_ goal: GoalProfile) throws {
        let predicate = #Predicate<GoalProfileRecord> { $0.profileKey == "primary" }
        var descriptor = FetchDescriptor<GoalProfileRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first
        if let existing {
            existing.targetWeightKilograms = goal.targetWeightKilograms
            existing.dailyDeficitKcal = goal.dailyDeficitKcal
            existing.dailyProteinGrams = goal.dailyProteinGrams
            existing.effectiveFrom = goal.effectiveFrom
            existing.updatedAt = Date()
        } else {
            modelContext.insert(GoalProfileRecord(
                profileKey: "primary",
                targetWeightKilograms: goal.targetWeightKilograms,
                dailyDeficitKcal: goal.dailyDeficitKcal,
                dailyProteinGrams: goal.dailyProteinGrams,
                effectiveFrom: goal.effectiveFrom
            ))
        }
        try modelContext.save()
    }

    func confirmedPlanEntries() throws -> ConfirmedDailyLoopPlans {
        let events = try modelContext.fetch(FetchDescriptor<ScheduleEvent>())
        let workoutPlans = events
            .compactMap { ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) }
            .sorted {
                let leftDate = $0.draft.scheduledAt ?? .distantPast
                let rightDate = $1.draft.scheduledAt ?? .distantPast
                return leftDate == rightDate
                    ? $0.actionID.uuidString < $1.actionID.uuidString
                    : leftDate > rightDate
            }
        let trainingPlans = events
            .compactMap { ConfirmedTrainingPlanEntry.decode(notes: $0.notes) }
            .sorted { lhs, rhs in
                if lhs.draft.createdAt != rhs.draft.createdAt {
                    return lhs.draft.createdAt > rhs.draft.createdAt
                }
                return lhs.draft.id.uuidString < rhs.draft.id.uuidString
            }
        return ConfirmedDailyLoopPlans(workoutPlans: workoutPlans, trainingPlans: trainingPlans)
    }

    func dailyLoopSnapshot(
        asOf date: Date,
        dailyBrief: DailyHealthBrief?,
        pendingActions: [PendingAction]
    ) throws -> DailyLoopSnapshot {
        let plans = try confirmedPlanEntries()
        return DailyLoopSnapshotComposer(calendar: calendar).compose(
            asOf: date,
            dailyBrief: dailyBrief,
            pendingActions: pendingActions,
            workoutPlans: plans.workoutPlans,
            trainingPlans: plans.trainingPlans
        )
    }

    private func cachedDailyBrief(
        _ brief: DailyHealthBrief,
        snapshotHash: String,
        in context: ModelContext
    ) throws -> DailyHealthBrief {
        let key = "daily:\(dayKey(brief.dayStart))"
        let predicate = #Predicate<DailyBriefRecord> { $0.cacheKey == key }
        var descriptor = FetchDescriptor<DailyBriefRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        if let existing,
           existing.snapshotHash == snapshotHash,
           existing.algorithmVersion == brief.algorithmVersion,
           let cached = try? makeDecoder().decode(DailyHealthBrief.self, from: existing.payloadData) {
            return cached
        }
        let payload = try encode(brief)
        if let existing {
            existing.snapshotHash = snapshotHash
            existing.algorithmVersion = brief.algorithmVersion
            existing.payloadData = payload
            existing.generatedAt = Date()
        } else {
            context.insert(DailyBriefRecord(
                cacheKey: key,
                dayKey: dayKey(brief.dayStart),
                snapshotHash: snapshotHash,
                algorithmVersion: brief.algorithmVersion,
                payloadData: payload
            ))
        }
        try context.save()
        return brief
    }

    private func cachedWeeklyBrief(
        _ brief: WeeklyHealthBrief,
        snapshotHash: String,
        in context: ModelContext
    ) throws -> WeeklyHealthBrief {
        let key = "weekly:\(dayKey(brief.weekStart))"
        let predicate = #Predicate<WeeklyBriefRecord> { $0.cacheKey == key }
        var descriptor = FetchDescriptor<WeeklyBriefRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        if let existing,
           existing.snapshotHash == snapshotHash,
           existing.algorithmVersion == brief.algorithmVersion,
           let cached = try? makeDecoder().decode(WeeklyHealthBrief.self, from: existing.payloadData) {
            return cached
        }
        let payload = try encode(brief)
        if let existing {
            existing.snapshotHash = snapshotHash
            existing.algorithmVersion = brief.algorithmVersion
            existing.payloadData = payload
            existing.generatedAt = Date()
        } else {
            context.insert(WeeklyBriefRecord(
                cacheKey: key,
                weekKey: dayKey(brief.weekStart),
                snapshotHash: snapshotHash,
                algorithmVersion: brief.algorithmVersion,
                payloadData: payload
            ))
        }
        try context.save()
        return brief
    }

    private func hash(
        days: [HealthIntelligenceDay],
        goal: GoalProfile?,
        algorithmVersion: String,
        plannedWorkoutTomorrow: Bool? = nil
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(CacheInput(
            days: days,
            goal: goal,
            algorithmVersion: algorithmVersion,
            plannedWorkoutTomorrow: plannedWorkoutTomorrow
        ))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func previousWeekStart(containing date: Date) -> Date {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2
        let currentStart = weekCalendar.dateInterval(of: .weekOfYear, for: calendar.startOfDay(for: date))?.start
            ?? calendar.startOfDay(for: date)
        return weekCalendar.date(byAdding: .day, value: -7, to: currentStart) ?? currentStart
    }

    private func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

struct HealthIntelligenceRefreshSnapshot: Sendable {
    let dailyBrief: DailyHealthBrief?
    let weeklyBrief: WeeklyHealthBrief?
    let updatesWeeklyBrief: Bool
}

struct HealthIntelligenceCachedBriefs: Sendable {
    let hasDailyRecord: Bool
    let dailyBrief: DailyHealthBrief?
    let hasWeeklyRecord: Bool
    let weeklyBrief: WeeklyHealthBrief?
}

struct ConfirmedDailyLoopPlans: Sendable {
    let workoutPlans: [ConfirmedWorkoutPlanEntry]
    let trainingPlans: [ConfirmedTrainingPlanEntry]
}

private struct CacheInput: Codable {
    let days: [HealthIntelligenceDay]
    let goal: GoalProfile?
    let algorithmVersion: String
    let plannedWorkoutTomorrow: Bool?
}
