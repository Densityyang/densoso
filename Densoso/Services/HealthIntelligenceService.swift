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
            let days = try loadDays(through: date, in: context)
            let goal = try goalProfile(asOf: date, in: context)
            guard let result = engine.makeDailyBrief(days: days, goals: goal) else {
                dailyBrief = nil
                return nil
            }
            let snapshotHash = try hash(days: days, goal: goal, algorithmVersion: result.dailyBrief.algorithmVersion)
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
        let dailyRecords = (try? context.fetch(FetchDescriptor<DailyBriefRecord>())) ?? []
        let weeklyRecords = (try? context.fetch(FetchDescriptor<WeeklyBriefRecord>())) ?? []
        if let record = dailyRecords.max(by: { $0.generatedAt < $1.generatedAt }) {
            dailyBrief = try? decoder.decode(DailyHealthBrief.self, from: record.payloadData)
        }
        if let record = weeklyRecords.max(by: { $0.generatedAt < $1.generatedAt }) {
            weeklyBrief = try? decoder.decode(WeeklyHealthBrief.self, from: record.payloadData)
        }
    }

    func healthContextSummary(asOf date: Date = Date()) throws -> HealthContextSummary? {
        let context = ModelContext(modelContainer)
        let days = try loadDays(through: date, in: context)
        guard let result = engine.makeDailyBrief(
            days: days,
            goals: try goalProfile(asOf: date, in: context)
        ) else { return nil }
        return result.dailyBrief.contextSummary
    }

    func goalProfile(asOf date: Date = Date()) throws -> GoalProfile? {
        try goalProfile(asOf: date, in: ModelContext(modelContainer))
    }

    func saveGoalProfile(_ goal: GoalProfile) throws {
        let context = ModelContext(modelContainer)
        let existing = try context.fetch(FetchDescriptor<GoalProfileRecord>())
            .first(where: { $0.profileKey == "primary" })
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

    private func goalProfile(asOf date: Date, in context: ModelContext) throws -> GoalProfile? {
        try context.fetch(FetchDescriptor<GoalProfileRecord>())
            .filter { $0.profileKey == "primary" && $0.effectiveFrom <= date }
            .max(by: { $0.effectiveFrom < $1.effectiveFrom })
            .map {
                GoalProfile(
                    effectiveFrom: $0.effectiveFrom,
                    targetWeightKilograms: $0.targetWeightKilograms,
                    dailyDeficitKcal: $0.dailyDeficitKcal,
                    dailyProteinGrams: $0.dailyProteinGrams
                )
            }
    }

    private func loadDays(through date: Date, in context: ModelContext) throws -> [HealthIntelligenceDay] {
        let end = calendar.startOfDay(for: date)
        // The report uses a prior Monday-based week. On Sunday, its start may be
        // 13 days behind `end`; retain that full week plus its 28-day baseline.
        guard let start = calendar.date(byAdding: .day, value: -41, to: end) else { return [] }

        let snapshots = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
        let decoder = makeDecoder()
        var snapshotByDay: [Date: DailyHealthSnapshot] = [:]
        for record in snapshots {
            guard let snapshot = try? decoder.decode(DailyHealthSnapshot.self, from: record.payloadData) else { continue }
            let day = calendar.startOfDay(for: snapshot.dayStart)
            if day >= start && day <= end { snapshotByDay[day] = snapshot }
        }

        let dailyMetrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        var metricsByDay: [Date: DailyMetrics] = [:]
        for metric in dailyMetrics {
            let day = calendar.startOfDay(for: metric.date)
            if day >= start && day <= end { metricsByDay[day] = metric }
        }

        let localWeights = try context.fetch(FetchDescriptor<WeightRecord>())
            .filter { $0.measuredAt >= start && $0.measuredAt < (calendar.date(byAdding: .day, value: 1, to: end) ?? end) }
        let weightsByDay = Dictionary(grouping: localWeights, by: { calendar.startOfDay(for: $0.measuredAt) })
        let meals = try context.fetch(FetchDescriptor<MealRecord>())
            .filter { $0.date >= start && $0.date < (calendar.date(byAdding: .day, value: 1, to: end) ?? end) }
        let mealsByDay = Dictionary(grouping: meals, by: { calendar.startOfDay(for: $0.date) })
        let workoutRecords = try context.fetch(FetchDescriptor<WorkoutRecord>())
            .filter { $0.date >= start && $0.date < (calendar.date(byAdding: .day, value: 1, to: end) ?? end) }
        var days: [HealthIntelligenceDay] = []
        for offset in 0...41 {
            guard let day = calendar.date(byAdding: .day, value: offset - 41, to: end) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            guard dayStart >= start && dayStart <= end else { continue }
            let snapshot = snapshotByDay[dayStart]
            let samples = snapshot?.healthKitSamples ?? []
            let localWeightPoints = (weightsByDay[dayStart] ?? []).map { (date: $0.measuredAt, value: $0.kilograms) }
            let healthWeightPoints = samples
                .filter { $0.metric == .bodyMass }
                .compactMap { sample -> (date: Date, value: Double)? in
                    guard let value = sample.value else { return nil }
                    return (sample.endDate, value)
                }
            var weightPoints = localWeightPoints + healthWeightPoints
            if weightPoints.isEmpty, let fallbackWeight = snapshot?.weightKilograms {
                weightPoints = [(date: dayStart, value: fallbackWeight)]
            }
            let weightSamples = weightPoints.sorted { $0.date < $1.date }.map { $0.value }
            let sleep = samples.compactMap { sample -> SleepSampleInterval? in
                guard sample.metric == .sleepAnalysis,
                      let category = Self.sleepStage(from: sample.categoryValue) else { return nil }
                return SleepSampleInterval(
                    startDate: sample.startDate,
                    endDate: sample.endDate,
                    stage: category,
                    sourceBundleIdentifier: sample.sourceBundleIdentifier,
                    deviceModel: sample.deviceModel
                )
            }
            let workouts = (workoutRecords.filter { calendar.startOfDay(for: $0.date) == dayStart }).map { record in
                let startAt = record.date
                let endAt = startAt.addingTimeInterval(Double(max(record.durationMinutes, 0)) * 60)
                let effort = samples
                    .filter { $0.metric == .workoutEffort && $0.endDate >= startAt && $0.startDate <= endAt }
                    .max { overlap($0, start: startAt, end: endAt) < overlap($1, start: startAt, end: endAt) }?
                    .value
                return TrainingWorkoutInput(
                    startedAt: record.date,
                    durationMinutes: Double(record.durationMinutes),
                    effortScore: effort,
                    intensity: record.intensity
                )
            }
            let metric = metricsByDay[dayStart]
            let dailyMeals = mealsByDay[dayStart] ?? []
            let proteinGrams: Double? = !dailyMeals.isEmpty && dailyMeals.allSatisfy { $0.proteinLikelyG != nil }
                ? dailyMeals.compactMap(\.proteinLikelyG).reduce(0, +)
                : nil
            let energyIntake = snapshot.flatMap { $0.energyIntakeKcal?.likely }
                ?? metric.flatMap { $0.mealCount > 0 ? Double($0.totalIntakeKcal) : nil }
            let dailyDeficit = metric.flatMap { value in
                value.energyQuality != "unavailable" && !value.requiresRecompute
                    ? Double(value.deficitKcal)
                    : nil
            }
            days.append(HealthIntelligenceDay(
                dayStart: dayStart,
                energyIntakeKcal: energyIntake,
                proteinGrams: proteinGrams,
                dailyDeficitKcal: energyIntake == nil ? nil : dailyDeficit,
                activeEnergyKcal: snapshot?.activeEnergyForProjection,
                stepCount: snapshot?.stepCountForProjection,
                exerciseMinutes: snapshot?.exerciseMinutesForProjection,
                weightSamplesKilograms: weightSamples,
                sleepSamples: sleep,
                heartRateSamples: samples.filter { $0.metric == .heartRate }.compactMap(\.value),
                restingHeartRateSamples: samples.filter { $0.metric == .restingHeartRate }.compactMap(\.value),
                heartRateVariabilitySamples: samples.filter { $0.metric == .heartRateVariabilitySDNN }.compactMap(\.value),
                respiratoryRateSamples: samples.filter { $0.metric == .respiratoryRate }.compactMap(\.value),
                wristTemperatureSamples: samples.filter { $0.metric == .wristTemperature }.compactMap(\.value),
                workouts: workouts
            ))
        }
        return days
    }

    private func cachedDailyBrief(
        _ brief: DailyHealthBrief,
        snapshotHash: String,
        in context: ModelContext
    ) throws -> DailyHealthBrief {
        let key = "daily:\(dayKey(brief.dayStart))"
        let descriptor = FetchDescriptor<DailyBriefRecord>()
        if let record = try context.fetch(descriptor).first(where: { $0.cacheKey == key }),
           record.snapshotHash == snapshotHash,
           record.algorithmVersion == brief.algorithmVersion,
           let cached = try? makeDecoder().decode(DailyHealthBrief.self, from: record.payloadData) {
            return cached
        }
        let record = try context.fetch(descriptor).first(where: { $0.cacheKey == key })
        let payload = try encode(brief)
        if let record {
            record.snapshotHash = snapshotHash
            record.algorithmVersion = brief.algorithmVersion
            record.payloadData = payload
            record.generatedAt = Date()
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
        let descriptor = FetchDescriptor<WeeklyBriefRecord>()
        if let record = try context.fetch(descriptor).first(where: { $0.cacheKey == key }),
           record.snapshotHash == snapshotHash,
           record.algorithmVersion == brief.algorithmVersion,
           let cached = try? makeDecoder().decode(WeeklyHealthBrief.self, from: record.payloadData) {
            return cached
        }
        let record = try context.fetch(descriptor).first(where: { $0.cacheKey == key })
        let payload = try encode(brief)
        if let record {
            record.snapshotHash = snapshotHash
            record.algorithmVersion = brief.algorithmVersion
            record.payloadData = payload
            record.generatedAt = Date()
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
        algorithmVersion: String
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(CacheInput(days: days, goal: goal, algorithmVersion: algorithmVersion))
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

    private func overlap(_ sample: HealthSampleSnapshot, start: Date, end: Date) -> TimeInterval {
        max(min(sample.endDate, end).timeIntervalSince(max(sample.startDate, start)), 0)
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

    private static func sleepStage(from rawValue: String?) -> SleepStage? {
        switch rawValue {
        case "inBed", "0": .inBed
        case "awake", "2": .awake
        case "asleepCore", "3": .asleepCore
        case "asleepDeep", "4": .asleepDeep
        case "asleepREM", "5": .asleepREM
        case "asleepUnspecified", "asleep", "1", "6": .asleepUnspecified
        default: nil
        }
    }
}

private struct CacheInput: Codable {
    let days: [HealthIntelligenceDay]
    let goal: GoalProfile?
    let algorithmVersion: String
}
