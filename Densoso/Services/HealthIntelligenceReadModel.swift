import DensosoDomain
import Foundation
import SwiftData

/// Shared read-only loader and deterministic calculations used by
/// `HealthProjectionActor` for both Agent reads and explicit brief refreshes.
struct HealthIntelligenceReadModel: Sendable {
    static let workoutFetchBatchSize = 64
    static let weightFetchBatchSize = 64
    static let schedulePlanFetchBatchSize = 64
    static let subjectiveCheckInLookbackDays = 7
    static let subjectiveCheckInFetchLimit = 128

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
        let subjective = try subjectiveContext(asOf: date, in: context)
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
                aggregateSummary: nil,
                subjectiveContext: subjective
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
            aggregateSummary: brief.contextSummary,
            subjectiveContext: subjective
        )
    }

    func subjectiveContext(asOf date: Date, in context: ModelContext) throws -> SubjectiveHealthContext? {
        let referenceDate = min(date, Date())
        let today = calendar.startOfDay(for: referenceDate)
        let userReportedSource = "userReported"
        var entries: [SubjectiveHealthEntry] = []
        for daysBack in 0..<Self.subjectiveCheckInLookbackDays {
            guard let dayStart = calendar.date(byAdding: .day, value: -daysBack, to: today),
                  let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                continue
            }

            let predicate = #Predicate<DailyCheckInRecord> {
                $0.occurredAt >= dayStart
                    && $0.occurredAt < nextDayStart
                    && $0.occurredAt <= referenceDate
                    && $0.sourceRaw == userReportedSource
            }
            var descriptor = FetchDescriptor<DailyCheckInRecord>(
                predicate: predicate,
                sortBy: [
                    SortDescriptor(\.occurredAt, order: .reverse),
                    SortDescriptor(\.createdAt, order: .reverse),
                ]
            )
            descriptor.fetchLimit = Self.subjectiveCheckInFetchLimit
            let candidates = try context.fetch(descriptor).sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString > $1.id.uuidString
            }
            guard let record = candidates.first(where: {
                UserReportedEnergy(rawValue: $0.energyRaw) != nil
                    && UserReportedStress(rawValue: $0.stressRaw) != nil
                    && SubjectiveSleepQuality(rawValue: $0.subjectiveSleepRaw) != nil
            }),
                  let energy = UserReportedEnergy(rawValue: record.energyRaw),
                  let stress = UserReportedStress(rawValue: record.stressRaw),
                  let sleep = SubjectiveSleepQuality(rawValue: record.subjectiveSleepRaw) else {
                continue
            }
            entries.append(SubjectiveHealthEntry(
                dayStart: dayStart,
                occurredAt: record.occurredAt,
                energy: energy,
                stress: stress,
                subjectiveSleep: sleep,
                evidenceKey: "userReportedCheckIn.\(record.id.uuidString.lowercased())"
            ))
        }
        guard !entries.isEmpty else { return nil }
        return SubjectiveHealthContext(asOf: referenceDate, entries: entries)
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
        let workoutPlanPrefix = ConfirmedWorkoutPlanEntry.notesPrefix
        let trainingPlanPrefix = ConfirmedTrainingPlanEntry.notesPrefix
        let ordinaryEventPredicate = #Predicate<ScheduleEvent> { event in
            event.startTime >= tomorrow && event.startTime < end
                && event.notes?.contains(workoutPlanPrefix) != true
                && event.notes?.contains(trainingPlanPrefix) != true
        }

        var ordinaryEventDescriptor = FetchDescriptor<ScheduleEvent>(predicate: ordinaryEventPredicate)
        ordinaryEventDescriptor.fetchLimit = 1
        let ordinaryEvents = try context.fetch(ordinaryEventDescriptor)
        let hasOrdinaryEvent = !ordinaryEvents.isEmpty

        let planPredicate = #Predicate<ScheduleEvent> { event in
            event.startTime >= tomorrow && event.startTime < end
                && (event.notes?.contains(workoutPlanPrefix) == true
                    || event.notes?.contains(trainingPlanPrefix) == true)
        }
        let planSortDescriptors: [SortDescriptor<ScheduleEvent>] = [
            SortDescriptor(\ScheduleEvent.startTime),
            SortDescriptor(\ScheduleEvent.date),
            SortDescriptor(\ScheduleEvent.createdAt),
            SortDescriptor(\ScheduleEvent.title),
            SortDescriptor(\ScheduleEvent.notes),
        ]
        var planDescriptor = FetchDescriptor<ScheduleEvent>(
            predicate: planPredicate,
            sortBy: planSortDescriptors
        )
        planDescriptor.fetchLimit = Self.schedulePlanFetchBatchSize
        var planOffset = 0
        var hasPlanEvent = false

        while true {
            planDescriptor.fetchOffset = planOffset
            let page = try context.fetch(planDescriptor)
            guard !page.isEmpty else { break }
            hasPlanEvent = true

            for event in page {
                if let entry = ConfirmedWorkoutPlanEntry.decode(notes: event.notes),
                   entry.state != .terminal {
                    return true
                }
                if let entry = ConfirmedTrainingPlanEntry.decode(notes: event.notes),
                   entry.state != .terminal {
                    return true
                }
            }

            guard page.count == Self.schedulePlanFetchBatchSize else { break }
            planOffset += page.count
        }

        return (hasOrdinaryEvent || hasPlanEvent) ? false : nil
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
        let weightSortBy = [
            SortDescriptor(\WeightRecord.measuredAt),
            SortDescriptor(\WeightRecord.id),
        ]
        var localWeights: [WeightRecord] = []
        var weightCursor: WeightCursor?
        while true {
            let predicate: Predicate<WeightRecord>
            if let weightCursor {
                let cursorMeasuredAt = weightCursor.measuredAt
                let cursorID = weightCursor.id
                predicate = #Predicate<WeightRecord> { record in
                    record.measuredAt >= start && record.measuredAt < exclusiveEnd
                        && (record.measuredAt > cursorMeasuredAt
                            || (record.measuredAt == cursorMeasuredAt && record.id > cursorID))
                }
            } else {
                predicate = weightPredicate
            }
            var descriptor = FetchDescriptor<WeightRecord>(predicate: predicate, sortBy: weightSortBy)
            descriptor.fetchLimit = Self.weightFetchBatchSize
            let batch = try context.fetch(descriptor)
            guard let last = batch.last else { break }
            localWeights.append(contentsOf: batch)
            weightCursor = WeightCursor(measuredAt: last.measuredAt, id: last.id)
        }
        let weightsByDay = Dictionary(grouping: localWeights, by: { calendar.startOfDay(for: $0.measuredAt) })
        let workoutPredicate = #Predicate<WorkoutRecord> {
            $0.date >= start && $0.date < exclusiveEnd
        }
        let workoutSortBy = [
            SortDescriptor(\WorkoutRecord.date),
            SortDescriptor(\WorkoutRecord.id),
        ]
        var workoutRecords: [WorkoutRecord] = []
        var workoutCursor: WorkoutCursor?
        while true {
            let predicate: Predicate<WorkoutRecord>
            if let workoutCursor {
                let cursorDate = workoutCursor.date
                let cursorID = workoutCursor.id
                predicate = #Predicate<WorkoutRecord> { record in
                    record.date >= start && record.date < exclusiveEnd
                        && (record.date > cursorDate
                            || (record.date == cursorDate && record.id > cursorID))
                }
            } else {
                predicate = workoutPredicate
            }
            var descriptor = FetchDescriptor<WorkoutRecord>(predicate: predicate, sortBy: workoutSortBy)
            descriptor.fetchLimit = Self.workoutFetchBatchSize
            let batch = try context.fetch(descriptor)
            guard let last = batch.last else { break }
            workoutRecords.append(contentsOf: batch)
            workoutCursor = WorkoutCursor(date: last.date, id: last.id)
        }
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
            let metricReadResult = metric.map(DailyMetricsReadModelMapper.make)
            let proteinGrams = metricReadResult?.proteinG.value
            let energyIntake = metricReadResult?.intake.value?.likely
            let dailyDeficit = metricReadResult?.deficit.value?.likely
            days.append(HealthIntelligenceDay(
                dayStart: dayStart,
                energyIntakeKcal: energyIntake,
                proteinGrams: proteinGrams,
                dailyDeficitKcal: dailyDeficit,
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

private struct WorkoutCursor {
    let date: Date
    let id: UUID
}

private struct WeightCursor {
    let measuredAt: Date
    let id: UUID
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
