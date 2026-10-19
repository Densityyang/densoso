import DensosoDomain
import Foundation
import SwiftData

/// Shared read-only loader and deterministic calculations used by
/// `HealthProjectionActor` for both Agent reads and explicit brief refreshes.
struct HealthIntelligenceReadModel: Sendable {
    static let mealFetchBatchSize = 64

    private let calendar: Calendar
    private let engine: HealthIntelligenceEngine

    init(calendar: Calendar) {
        self.calendar = calendar
        self.engine = HealthIntelligenceEngine(calendar: calendar)
    }

    func healthContextSummary(asOf date: Date, in context: ModelContext) throws -> HealthContextSummary? {
        let days = try loadDays(through: date, in: context)
        let plannedWorkout = try plannedWorkoutTomorrow(asOf: date, in: context)
        return engine.makeDailyBrief(
            days: days,
            goals: try goalProfile(asOf: date, in: context),
            plannedWorkoutTomorrow: plannedWorkout
        )?.dailyBrief.contextSummary
    }

    func healthNarrativeContext(asOf date: Date, in context: ModelContext) throws -> HealthNarrativeContext {
        let days = try loadDays(through: date, in: context)
        let result = engine.makeDailyBrief(
            days: days,
            goals: try goalProfile(asOf: date, in: context),
            plannedWorkoutTomorrow: try plannedWorkoutTomorrow(asOf: date, in: context)
        )
        guard let brief = result?.dailyBrief else {
            return HealthNarrativeContext(
                healthState: nil,
                evidence: [],
                recommendationCandidates: [],
                aggregateSummary: nil
            )
        }
        let state = brief.healthState
        let stateEvidence = (state?.domains ?? []).flatMap { domain in
            domain.evidenceKeys.map { EvidenceReference(key: $0, source: domain.domain.rawValue) }
        } + (state?.recovery.evidence ?? [])
            + (state?.tomorrowGuidance?.reasons ?? [])
            + brief.vitalTrends.map {
                EvidenceReference(key: $0.evidenceKey, source: $0.metric.rawValue)
            }
        return HealthNarrativeContext(
            healthState: state,
            evidence: stateEvidence,
            recommendationCandidates: brief.recommendations,
            aggregateSummary: brief.contextSummary
        )
    }

    func todayHealthState(asOf date: Date, in context: ModelContext) throws -> HealthStateV2? {
        let days = try loadDays(through: date, in: context)
        let plannedWorkout = try plannedWorkoutTomorrow(asOf: date, in: context)
        return engine.makeDailyBrief(
            days: days,
            goals: try goalProfile(asOf: date, in: context),
            plannedWorkoutTomorrow: plannedWorkout
        )?.dailyBrief.healthState
    }

    func healthHistory(
        from startDate: Date,
        through endDate: Date,
        in context: ModelContext
    ) throws -> [HealthStateHistoryPoint] {
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard startDay <= endDay else { throw HealthHistoryQueryError.invalidRange }
        guard endDay <= calendar.startOfDay(for: Date()) else { throw HealthHistoryQueryError.futureDate }
        let dayCount = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? -1
        guard (0..<HealthHistoryQueryError.maximumDays).contains(dayCount) else {
            throw HealthHistoryQueryError.rangeTooLarge
        }
        guard let baselineStart = calendar.date(byAdding: .day, value: -41, to: startDay) else {
            throw HealthHistoryQueryError.invalidRange
        }

        let days = try loadDays(from: baselineStart, through: endDay, in: context)
        var points: [HealthStateHistoryPoint] = []
        for offset in 0...dayCount {
            guard let targetDay = calendar.date(byAdding: .day, value: offset, to: startDay) else { continue }
            let inputs = days.filter { calendar.startOfDay(for: $0.dayStart) <= targetDay }
            guard let state = engine.makeDailyBrief(
                days: inputs,
                goals: try goalProfile(asOf: targetDay, in: context)
            )?.dailyBrief.healthState else { continue }
            points.append(HealthStateHistoryPoint(
                date: targetDay,
                state: HealthStateV2(
                    domains: state.domains,
                    recovery: state.recovery,
                    trainingLoad: state.trainingLoad,
                    tomorrowGuidance: nil
                )
            ))
        }
        return points
    }

    func goalProfile(asOf date: Date, in context: ModelContext) throws -> GoalProfile? {
        let predicate = #Predicate<GoalProfileRecord> {
            $0.profileKey == "primary" && $0.effectiveFrom <= date
        }
        var descriptor = FetchDescriptor<GoalProfileRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\GoalProfileRecord.effectiveFrom, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return GoalProfile(
            effectiveFrom: record.effectiveFrom,
            targetWeightKilograms: record.targetWeightKilograms,
            dailyDeficitKcal: record.dailyDeficitKcal,
            dailyProteinGrams: record.dailyProteinGrams
        )
    }

    func loadDays(through date: Date, in context: ModelContext) throws -> [HealthIntelligenceDay] {
        let end = calendar.startOfDay(for: date)
        // Preserve the complete prior baseline plus the previous Monday-based week.
        guard let start = calendar.date(byAdding: .day, value: -41, to: end) else { return [] }
        return try loadDays(from: start, through: end, in: context)
    }

    func plannedWorkoutTomorrow(asOf date: Date, in context: ModelContext) throws -> Bool? {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            ?? calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: tomorrow) ?? tomorrow
        let predicate = #Predicate<ScheduleEvent> { event in
            event.startTime >= tomorrow && event.startTime < end
        }
        let events = try context.fetch(FetchDescriptor<ScheduleEvent>(predicate: predicate))
        guard !events.isEmpty else { return nil }
        return events.contains {
            guard let entry = ConfirmedWorkoutPlanEntry.decode(notes: $0.notes) else { return false }
            return entry.state != .terminal
        }
    }

    private func loadDays(
        from startDate: Date,
        through date: Date,
        in context: ModelContext
    ) throws -> [HealthIntelligenceDay] {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: date)
        guard start <= end,
              let dayCount = calendar.dateComponents([.day], from: start, to: end).day,
              dayCount >= 0,
              let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: end) else { return [] }

        let startKey = dayKey(start)
        let endKey = dayKey(end)
        let snapshotPredicate = #Predicate<DailyHealthSnapshotRecord> {
            $0.dayKey >= startKey && $0.dayKey <= endKey
        }
        let snapshots = try context.fetch(
            FetchDescriptor<DailyHealthSnapshotRecord>(
                predicate: snapshotPredicate,
                sortBy: [SortDescriptor(\DailyHealthSnapshotRecord.dayKey)]
            )
        )
        let decoder = makeDecoder()
        var snapshotByDay: [Date: DailyHealthSnapshot] = [:]
        for record in snapshots {
            guard let snapshot = try? decoder.decode(DailyHealthSnapshot.self, from: record.payloadData) else { continue }
            let day = calendar.startOfDay(for: snapshot.dayStart)
            if day >= start && day <= end { snapshotByDay[day] = snapshot }
        }

        let metricsPredicate = #Predicate<DailyMetrics> {
            $0.date >= start && $0.date < exclusiveEnd
        }
        let dailyMetrics = try context.fetch(
            FetchDescriptor<DailyMetrics>(
                predicate: metricsPredicate,
                sortBy: [SortDescriptor(\DailyMetrics.date)]
            )
        )
        var metricsByDay: [Date: DailyMetrics] = [:]
        for metric in dailyMetrics {
            let day = calendar.startOfDay(for: metric.date)
            if day >= start && day <= end { metricsByDay[day] = metric }
        }

        let weightPredicate = #Predicate<WeightRecord> {
            $0.measuredAt >= start && $0.measuredAt < exclusiveEnd
        }
        let localWeights = try context.fetch(
            FetchDescriptor<WeightRecord>(
                predicate: weightPredicate,
                sortBy: [SortDescriptor(\WeightRecord.measuredAt)]
            )
        )
        let weightsByDay = Dictionary(grouping: localWeights, by: { calendar.startOfDay(for: $0.measuredAt) })
        let proteinByDay = try mealProteinByDay(from: start, before: exclusiveEnd, in: context)
        let workoutPredicate = #Predicate<WorkoutRecord> {
            $0.date >= start && $0.date < exclusiveEnd
        }
        let workoutRecords = try context.fetch(
            FetchDescriptor<WorkoutRecord>(
                predicate: workoutPredicate,
                sortBy: [SortDescriptor(\WorkoutRecord.date)]
            )
        )
        let workoutsByDay = Dictionary(grouping: workoutRecords, by: { calendar.startOfDay(for: $0.date) })
        var days: [HealthIntelligenceDay] = []
        for offset in 0...dayCount {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            guard dayStart >= start && dayStart <= end else { continue }
            let snapshot = snapshotByDay[dayStart]
            let sampleSummary = snapshot?.healthKitSampleSummary
            func availableAggregate(_ metric: HealthMetricID) -> HealthMetricSampleAggregate? {
                if let state = snapshot?.healthReadStates?[metric.rawValue], state != .available { return nil }
                return sampleSummary?.aggregate(for: metric)
            }
            func dailyAverage(_ metric: HealthMetricID) -> [Double] {
                guard let value = availableAggregate(metric)?.averageValue else { return [] }
                return [value]
            }
            let localWeightPoints = (weightsByDay[dayStart] ?? []).map { (date: $0.measuredAt, value: $0.kilograms) }
            let healthWeightPoints: [(date: Date, value: Double)]
            if let aggregate = availableAggregate(.bodyMass),
               let date = aggregate.latestSampleAt,
               let value = aggregate.latestValue {
                healthWeightPoints = [(date: date, value: value)]
            } else {
                healthWeightPoints = []
            }
            var weightPoints = localWeightPoints + healthWeightPoints
            let bodyMassReadState = snapshot?.healthReadStates?[HealthMetricID.bodyMass.rawValue]
            if weightPoints.isEmpty,
               bodyMassReadState == nil || bodyMassReadState == .available,
               let fallbackWeight = snapshot?.weightKilograms {
                weightPoints = [(date: dayStart, value: fallbackWeight)]
            }
            let weightSamples = weightPoints.sorted { $0.date < $1.date }.map { $0.value }
            let workouts = (workoutsByDay[dayStart] ?? []).map { record in
                let effort = availableAggregate(.workoutEffort) != nil
                    ? sampleSummary?.effortScore(for: record.id)
                    : nil
                return TrainingWorkoutInput(
                    startedAt: record.date,
                    durationMinutes: Double(record.durationMinutes),
                    effortScore: effort,
                    intensity: record.intensity
                )
            }
            let metric = metricsByDay[dayStart]
            let proteinGrams = proteinByDay[dayStart]
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
                sleepSamples: [],
                sleepSummary: snapshot?.healthReadStates?[HealthMetricID.sleepAnalysis.rawValue] == nil
                    || snapshot?.healthReadStates?[HealthMetricID.sleepAnalysis.rawValue] == .available
                    ? sampleSummary?.sleep
                    : nil,
                heartRateSamples: dailyAverage(.heartRate),
                restingHeartRateSamples: dailyAverage(.restingHeartRate),
                heartRateVariabilitySamples: dailyAverage(.heartRateVariabilitySDNN),
                respiratoryRateSamples: dailyAverage(.respiratoryRate),
                wristTemperatureSamples: dailyAverage(.wristTemperature),
                workouts: workouts
            ))
        }
        return days
    }

    private func mealProteinByDay(
        from start: Date,
        before exclusiveEnd: Date,
        in context: ModelContext
    ) throws -> [Date: Double] {
        let sortBy = [
            SortDescriptor(\MealRecord.date),
            SortDescriptor(\MealRecord.sourceActionKey),
        ]
        var accumulators: [Date: DailyProteinAccumulator] = [:]
        var cursor: MealCursor?
        while true {
            let predicate: Predicate<MealRecord>
            if let cursor {
                let cursorDate = cursor.date
                let cursorSourceActionKey = cursor.sourceActionKey
                predicate = #Predicate<MealRecord> {
                    $0.date >= start && $0.date < exclusiveEnd
                        && ($0.date > cursorDate
                            || ($0.date == cursorDate && $0.sourceActionKey > cursorSourceActionKey))
                }
            } else {
                predicate = #Predicate<MealRecord> {
                    $0.date >= start && $0.date < exclusiveEnd
                }
            }
            var descriptor = FetchDescriptor<MealRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.mealFetchBatchSize
            let batch = try context.fetch(descriptor)
            guard !batch.isEmpty else { break }

            for meal in batch {
                cursor = MealCursor(date: meal.date, sourceActionKey: meal.sourceActionKey)
                let day = calendar.startOfDay(for: meal.date)
                accumulators[day, default: DailyProteinAccumulator()].add(meal.proteinLikelyG)
            }
        }

        var totals: [Date: Double] = [:]
        for (day, accumulator) in accumulators {
            if let total = accumulator.completeProteinTotal {
                totals[day] = total
            }
        }
        return totals
    }

    private func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

}

private struct MealCursor {
    let date: Date
    let sourceActionKey: String
}

private struct DailyProteinAccumulator {
    private(set) var hasMeals = false
    private(set) var hasMissingProtein = false
    private(set) var totalProteinGrams = 0.0

    mutating func add(_ proteinGrams: Double?) {
        hasMeals = true
        guard let proteinGrams else {
            hasMissingProtein = true
            return
        }
        totalProteinGrams += proteinGrams
    }

    var completeProteinTotal: Double? {
        hasMeals && !hasMissingProtein ? totalProteinGrams : nil
    }
}

struct HealthStateHistoryPoint: Equatable, Sendable {
    let date: Date
    let state: HealthStateV2
}

enum HealthHistoryQueryError: Error, LocalizedError, Equatable {
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
