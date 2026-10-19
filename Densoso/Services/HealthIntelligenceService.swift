import CryptoKit
import DensosoDomain
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class HealthIntelligenceService {
    private let modelContainer: ModelContainer
    private var calendar: Calendar
    private let engine: HealthIntelligenceEngine

    private(set) var dailyBrief: DailyHealthBrief?
    private(set) var weeklyBrief: WeeklyHealthBrief?
    private(set) var lastError: String?

    init(modelContainer: ModelContainer, calendar: Calendar = .current) {
        self.modelContainer = modelContainer
        self.calendar = calendar
        self.engine = HealthIntelligenceEngine(calendar: calendar)
    }

    @discardableResult
    func refresh(asOf date: Date = Date()) throws -> DailyHealthBrief? {
        lastError = nil
        do {
            let context = ModelContext(modelContainer)
            let reader = HealthIntelligenceReadModel(calendar: calendar)
            let days = try reader.loadDays(through: date, in: context)
            let goal = try reader.goalProfile(asOf: date, in: context)
            let plannedWorkout = try reader.plannedWorkoutTomorrow(asOf: date, in: context)
            guard let result = engine.makeDailyBrief(
                days: days,
                goals: goal,
                plannedWorkoutTomorrow: plannedWorkout
            ) else {
                dailyBrief = nil
                return nil
            }
            let snapshotHash = try hash(
                days: days,
                goal: goal,
                algorithmVersion: result.dailyBrief.algorithmVersion,
                plannedWorkoutTomorrow: plannedWorkout
            )
            dailyBrief = try cachedDailyBrief(
                result.dailyBrief,
                snapshotHash: snapshotHash,
                in: context
            )

            let weekStart = previousWeekStart(containing: date)
            let weekly = engine.makeWeeklyBrief(days: days, weekStart: weekStart, goals: goal)
            let weeklyWindowStart = calendar.date(byAdding: .day, value: -28, to: weekStart) ?? weekStart
            let weeklyWindowEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            let weeklyHash = try hash(days: days.filter {
                let day = calendar.startOfDay(for: $0.dayStart)
                return day >= weeklyWindowStart && day < weeklyWindowEnd
            }, goal: goal, algorithmVersion: weekly.algorithmVersion)
            weeklyBrief = try cachedWeeklyBrief(
                weekly,
                snapshotHash: weeklyHash,
                in: context
            )
            return dailyBrief
        } catch {
            lastError = "无法更新健康摘要：\(error.localizedDescription)"
            throw error
        }
    }

    func loadCachedBriefs() {
        let context = ModelContext(modelContainer)
        let decoder = makeDecoder()
        var dailyDescriptor = FetchDescriptor<DailyBriefRecord>(
            sortBy: [SortDescriptor(\DailyBriefRecord.generatedAt, order: .reverse)]
        )
        dailyDescriptor.fetchLimit = 1
        var weeklyDescriptor = FetchDescriptor<WeeklyBriefRecord>(
            sortBy: [SortDescriptor(\WeeklyBriefRecord.generatedAt, order: .reverse)]
        )
        weeklyDescriptor.fetchLimit = 1
        if let record = try? context.fetch(dailyDescriptor).first {
            dailyBrief = try? decoder.decode(DailyHealthBrief.self, from: record.payloadData)
        }
        if let record = try? context.fetch(weeklyDescriptor).first {
            weeklyBrief = try? decoder.decode(WeeklyHealthBrief.self, from: record.payloadData)
        }
    }

    func healthContextSummary(asOf date: Date = Date()) throws -> HealthContextSummary? {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthContextSummary(asOf: date, in: ModelContext(modelContainer))
    }

    /// Returns bounded, deterministic inputs for a model-authored health narrative.
    /// This read path never refreshes or writes the daily/weekly brief caches.
    func healthNarrativeContext(asOf date: Date = Date()) throws -> HealthNarrativeContext {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthNarrativeContext(asOf: date, in: ModelContext(modelContainer))
    }

    /// Builds today's deterministic state without updating either persisted brief cache.
    /// Read-only agent tools use this path so a query does not cause a write as a side effect.
    func todayHealthState(asOf date: Date = Date()) throws -> HealthStateV2? {
        try HealthIntelligenceReadModel(calendar: calendar)
            .todayHealthState(asOf: date, in: ModelContext(modelContainer))
    }

    /// Returns deterministic, read-only daily health summaries for a bounded historical window.
    /// The same 41-day baseline used by the daily brief is loaded before the first requested day.
    func healthHistory(from startDate: Date, through endDate: Date) throws -> [HealthStateHistoryPoint] {
        try HealthIntelligenceReadModel(calendar: calendar)
            .healthHistory(from: startDate, through: endDate, in: ModelContext(modelContainer))
    }

    func goalProfile(asOf date: Date = Date()) throws -> GoalProfile? {
        try HealthIntelligenceReadModel(calendar: calendar)
            .goalProfile(asOf: date, in: ModelContext(modelContainer))
    }

    func saveGoalProfile(_ goal: GoalProfile) throws {
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<GoalProfileRecord> { $0.profileKey == "primary" }
        var descriptor = FetchDescriptor<GoalProfileRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        if let existing {
            existing.targetWeightKilograms = goal.targetWeightKilograms
            existing.dailyDeficitKcal = goal.dailyDeficitKcal
            existing.dailyProteinGrams = goal.dailyProteinGrams
            existing.effectiveFrom = goal.effectiveFrom
            existing.updatedAt = Date()
        } else {
            context.insert(GoalProfileRecord(
                profileKey: "primary",
                targetWeightKilograms: goal.targetWeightKilograms,
                dailyDeficitKcal: goal.dailyDeficitKcal,
                dailyProteinGrams: goal.dailyProteinGrams,
                effectiveFrom: goal.effectiveFrom
            ))
        }
        try context.save()
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
        let data = try encoder.encode(
            CacheInput(
                days: days,
                goal: goal,
                algorithmVersion: algorithmVersion,
                plannedWorkoutTomorrow: plannedWorkoutTomorrow
            )
        )
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

private struct CacheInput: Codable {
    let days: [HealthIntelligenceDay]
    let goal: GoalProfile?
    let algorithmVersion: String
    let plannedWorkoutTomorrow: Bool?
}

struct HealthStateHistoryPoint: Equatable, Sendable {
    let date: Date
    let state: HealthStateV2
}

enum HealthHistoryQueryError: Error, LocalizedError, Equatable {
    // Keep a compact daily report below the Agent tool-output limit.
    static let maximumDays = 14

    case invalidRange
    case rangeTooLarge
    case futureDate

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "健康历史日期范围无效。"
        case .rangeTooLarge:
            "健康状态历史一次最多查询 14 天。"
        case .futureDate:
            "健康状态历史不能查询未来日期。"
        }
    }
}
