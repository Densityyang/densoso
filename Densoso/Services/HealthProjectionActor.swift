import CryptoKit
import DensosoDomain
import Foundation
import SwiftData

/// Performs bounded reads and explicit deterministic projection refreshes on
/// the SwiftData model actor executor. Read-only Agent queries do not refresh or write caches.
@ModelActor
actor HealthProjectionActor {
    private static let confirmedPlanFetchBatchSize = 64
    private static let watchPlanSummaryLimit = 10
    private var calendar: Calendar = .current
    private var briefCacheGenerationFence = HealthBriefCacheGenerationFence()

    private enum WatchPlanCandidate {
        case workout(ConfirmedWorkoutPlanEntry)
        case training(ConfirmedTrainingPlanEntry, TrainingSessionDraft)
    }

    init(
        modelContainer: ModelContainer,
        calendar: Calendar = .current,
        briefCacheGenerationFence: HealthBriefCacheGenerationFence = HealthBriefCacheGenerationFence()
    ) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.calendar = calendar
        self.briefCacheGenerationFence = briefCacheGenerationFence
    }

    func refresh(
        asOf date: Date = Date(),
        cacheGeneration: UInt64
    ) throws -> HealthIntelligenceRefreshSnapshot {
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
                dailyBriefSourceFingerprint: nil,
                dailyBriefValidatedAt: nil,
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
            in: modelContext,
            cacheGeneration: cacheGeneration
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
            in: modelContext,
            cacheGeneration: cacheGeneration
        )
        return HealthIntelligenceRefreshSnapshot(
            dailyBrief: daily,
            dailyBriefSourceFingerprint: dailySnapshotHash,
            dailyBriefValidatedAt: date,
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
        let dailyBrief = dailyRecord.flatMap { try? decoder.decode(DailyHealthBrief.self, from: $0.payloadData) }
        return HealthIntelligenceCachedBriefs(
            hasDailyRecord: dailyRecord != nil,
            dailyBrief: dailyBrief,
            dailyBriefSourceFingerprint: dailyBrief == nil ? nil : dailyRecord?.snapshotHash,
            dailyBriefValidatedAt: nil,
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

    func subjectiveContext(asOf date: Date = Date()) throws -> SubjectiveHealthContext? {
        try HealthIntelligenceReadModel(calendar: calendar)
            .subjectiveContext(asOf: date, in: modelContext)
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
        try loadConfirmedPlanEntries(asOf: nil)
    }

    private func loadConfirmedPlanEntries(asOf date: Date?) throws -> ConfirmedDailyLoopPlans {
        let workoutPlanPrefix = ConfirmedWorkoutPlanEntry.notesPrefix
        let trainingPlanPrefix = ConfirmedTrainingPlanEntry.notesPrefix
        let predicate = #Predicate<ScheduleEvent> {
            $0.notes?.contains(workoutPlanPrefix) == true
                || $0.notes?.contains(trainingPlanPrefix) == true
        }

        let planWindow: Range<Date>? = {
            guard let date else { return nil }
            let dayStart = calendar.startOfDay(for: date)
            guard let throughTomorrow = calendar.date(byAdding: .day, value: 2, to: dayStart) else {
                return dayStart..<dayStart
            }
            return dayStart..<throughTomorrow
        }()
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
        var workoutPlans: [ConfirmedWorkoutPlanEntry] = []
        var trainingPlans: [ConfirmedTrainingPlanEntry] = []
        var watchPlanCandidates: [WatchPlanCandidate] = []

        while true {
            descriptor.fetchOffset = offset
            let page = try modelContext.fetch(descriptor)
            guard !page.isEmpty else { break }

            for event in page {
                if let entry = ConfirmedWorkoutPlanEntry.decode(notes: event.notes) {
                    guard let planWindow else {
                        workoutPlans.append(entry)
                        continue
                    }
                    guard entry.state != .terminal,
                          let scheduledAt = entry.draft.scheduledAt,
                          planWindow.contains(scheduledAt) else { continue }
                    watchPlanCandidates.append(.workout(entry))
                    Self.retainEarliestWatchPlanCandidates(&watchPlanCandidates)
                    continue
                }

                guard let entry = ConfirmedTrainingPlanEntry.decode(notes: event.notes) else { continue }
                guard let planWindow else {
                    trainingPlans.append(entry)
                    continue
                }
                guard entry.state != .terminal else { continue }

                var plan = entry.draft
                plan.sessions = entry.draft.sessions.filter { session in
                    !session.isRestDay && planWindow.contains(session.date)
                }
                guard !plan.sessions.isEmpty else { continue }
                for session in plan.sessions {
                    watchPlanCandidates.append(.training(entry, session))
                    Self.retainEarliestWatchPlanCandidates(&watchPlanCandidates)
                }
            }

            guard page.count == Self.confirmedPlanFetchBatchSize else { break }
            offset += page.count
        }

        if planWindow != nil {
            workoutPlans = watchPlanCandidates.compactMap { candidate in
                guard case .workout(let entry) = candidate else { return nil }
                return entry
            }
            let trainingSessions = watchPlanCandidates.compactMap { candidate -> (ConfirmedTrainingPlanEntry, TrainingSessionDraft)? in
                guard case .training(let entry, let session) = candidate else { return nil }
                return (entry, session)
            }
            let sessionsByPlan = Dictionary(grouping: trainingSessions, by: { $0.0.actionID })
            trainingPlans = sessionsByPlan.values.compactMap { candidates in
                guard let first = candidates.first else { return nil }
                let entry = first.0
                var draft = entry.draft
                draft.sessions = candidates
                    .map { $0.1 }
                    .sorted {
                        if $0.date != $1.date { return $0.date < $1.date }
                        return $0.id.uuidString < $1.id.uuidString
                    }
                let retainedSessionIDs = Set(draft.sessions.map(\.id))
                return ConfirmedTrainingPlanEntry(
                    actionID: entry.actionID,
                    idempotencyKey: entry.idempotencyKey,
                    draft: draft,
                    scheduledSessionIDs: entry.scheduledSessionIDs.filter { retainedSessionIDs.contains($0) },
                    state: entry.state,
                    lastError: entry.lastError
                )
            }
        }

        let sortedWorkoutPlans = workoutPlans.sorted { lhs, rhs in
            let leftDate = lhs.draft.scheduledAt ?? .distantPast
            let rightDate = rhs.draft.scheduledAt ?? .distantPast
            if leftDate != rightDate {
                return planWindow == nil ? leftDate > rightDate : leftDate < rightDate
            }
            return lhs.actionID.uuidString < rhs.actionID.uuidString
        }
        let sortedTrainingPlans = trainingPlans
            .sorted { lhs, rhs in
                if lhs.draft.createdAt != rhs.draft.createdAt {
                    return lhs.draft.createdAt > rhs.draft.createdAt
                }
                return lhs.draft.id.uuidString < rhs.draft.id.uuidString
            }
        return ConfirmedDailyLoopPlans(workoutPlans: sortedWorkoutPlans, trainingPlans: sortedTrainingPlans)
    }

    private static func retainEarliestWatchPlanCandidates(_ candidates: inout [WatchPlanCandidate]) {
        candidates.sort { lhs, rhs in
            func orderKey(_ candidate: WatchPlanCandidate) -> (date: Date, summaryID: String, planID: String) {
                switch candidate {
                case .workout(let entry):
                    return (
                        entry.draft.scheduledAt ?? .distantFuture,
                        entry.actionID.uuidString,
                        entry.actionID.uuidString
                    )
                case .training(let entry, let session):
                    return (session.date, session.id.uuidString, entry.actionID.uuidString)
                }
            }
            let left = orderKey(lhs)
            let right = orderKey(rhs)
            if left.date != right.date { return left.date < right.date }
            if left.summaryID != right.summaryID { return left.summaryID < right.summaryID }
            return left.planID < right.planID
        }
        if candidates.count > watchPlanSummaryLimit {
            candidates.removeLast(candidates.count - watchPlanSummaryLimit)
        }
    }

    func dailyLoopSnapshot(
        asOf date: Date,
        dailyBrief: DailyHealthBrief?,
        dailyBriefSourceFingerprint: String?,
        dailyBriefValidatedAt: Date?,
        pendingActions: [PendingAction]
    ) throws -> DailyLoopSnapshot {
        let plans = try loadConfirmedPlanEntries(asOf: date)
        let coverage = try dailyLoopMetricCoverage(on: date)
        return DailyLoopSnapshotComposer(calendar: calendar).compose(
            asOf: date,
            dailyBrief: dailyBrief,
            dailyBriefSourceFingerprint: dailyBriefSourceFingerprint,
            dailyBriefValidatedAt: dailyBriefValidatedAt,
            coverage: coverage,
            pendingActions: pendingActions,
            workoutPlans: plans.workoutPlans,
            trainingPlans: plans.trainingPlans
        )
    }

    private func dailyLoopMetricCoverage(on date: Date) throws -> DailyLoopMetricCoverage {
        let day = calendar.startOfDay(for: date)
        let predicate = #Predicate<DailyMetrics> { $0.date == day }
        var descriptor = FetchDescriptor<DailyMetrics>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let metric = try modelContext.fetch(descriptor).first else {
            return .unavailable
        }
        let result = DailyMetricsReadModelMapper.make(metric)
        return DailyLoopMetricCoverage(
            intake: result.intake.availability,
            expenditure: result.expenditure.availability,
            deficit: result.deficit.availability,
            proteinG: result.proteinG.availability,
            fatG: result.fatG.availability,
            carbsG: result.carbsG.availability
        )
    }

    private func cachedDailyBrief(
        _ brief: DailyHealthBrief,
        snapshotHash: String,
        in context: ModelContext,
        cacheGeneration: UInt64
    ) throws -> DailyHealthBrief {
        try briefCacheGenerationFence.withCurrentGeneration(cacheGeneration) {
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
            let generatedAt = Date()
            if let existing {
                existing.snapshotHash = snapshotHash
                existing.algorithmVersion = brief.algorithmVersion
                existing.payloadData = payload
                existing.generatedAt = generatedAt
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
    }

    private func cachedWeeklyBrief(
        _ brief: WeeklyHealthBrief,
        snapshotHash: String,
        in context: ModelContext,
        cacheGeneration: UInt64
    ) throws -> WeeklyHealthBrief {
        try briefCacheGenerationFence.withCurrentGeneration(cacheGeneration) {
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
    let dailyBriefSourceFingerprint: String?
    let dailyBriefValidatedAt: Date?
    let weeklyBrief: WeeklyHealthBrief?
    let updatesWeeklyBrief: Bool
}

struct HealthIntelligenceCachedBriefs: Sendable {
    let hasDailyRecord: Bool
    let dailyBrief: DailyHealthBrief?
    let dailyBriefSourceFingerprint: String?
    let dailyBriefValidatedAt: Date?
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
