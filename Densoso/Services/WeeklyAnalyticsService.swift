import DensosoDomain
import Foundation
import SwiftData

struct WeeklyTrendPoint: Identifiable, Equatable {
    let date: Date
    let deficit: MetricValue<SignedEstimateRange>
    let targetDeficitKcal: Int

    var id: Date { date }
    var hasData: Bool { deficit.value != nil }
    var deficitKcal: Int? {
        guard let likely = deficit.value?.likely,
              likely.isFinite,
              likely > Double(Int.min),
              likely < Double(Int.max) else { return nil }
        return Int(likely.rounded())
    }
}

struct WeeklyAnalyticsSnapshot: Equatable {
    let points: [WeeklyTrendPoint]
    let totalDeficitKcal: Int?
    let averageDailyDeficitKcal: Double?
    let projectedWeightLossKg: Double?
    let recordedDays: Int
    let energyCoverage: MetricCoverage

    var hasData: Bool { recordedDays > 0 }
}

/// Produces the dashboard's rolling seven-day series and keeps a fully covered
/// persisted report in sync with the DailyMetrics source.
@MainActor
struct WeeklyAnalyticsService {
    var calendar: Calendar = .current

    func load(
        referenceDate: Date = Date(),
        profile: UserProfile?,
        goal: GoalProfile? = nil,
        in modelContext: ModelContext
    ) throws -> WeeklyAnalyticsSnapshot {
        let today = calendar.startOfDay(for: referenceDate)
        let rollingStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? referenceDate
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: today)
            ?? DateInterval(start: rollingStart, end: tomorrow)
        let fetchStart = min(rollingStart, weekInterval.start)

        let predicate = #Predicate<DailyMetrics> { metric in
            metric.date >= fetchStart && metric.date < tomorrow
        }
        var descriptor = FetchDescriptor<DailyMetrics>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\DailyMetrics.date)]
        let metrics = try modelContext.fetch(descriptor)
        let target = max(goal?.dailyDeficitKcal ?? profile?.dailyDeficitTarget ?? 500, 0)

        var metricsByDay: [Date: DailyMetricsReadResult] = [:]
        for metric in metrics {
            metricsByDay[calendar.startOfDay(for: metric.date)] = DailyMetricsReadModelMapper.make(metric)
        }

        let points = (0..<7).compactMap { offset -> WeeklyTrendPoint? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: rollingStart) else { return nil }
            let result = metricsByDay[date]
            return WeeklyTrendPoint(
                date: date,
                deficit: result?.deficit ?? MetricValue(value: nil, availability: .unavailable),
                targetDeficitKcal: target
            )
        }
        let aggregate = DailyMetricsUsabilityPolicy.aggregateSignedRanges(
            points.map(\.deficit),
            expectedDays: 7
        )
        let total = aggregate.total.value?.likely
        let average = aggregate.coverage.availableDays > 0
            ? total.map { $0 / Double(aggregate.coverage.availableDays) }
            : nil
        let projectedLoss = total.map { $0 / 7_700 }

        let weekDays = max(
            (calendar.dateComponents([.day], from: calendar.startOfDay(for: weekInterval.start), to: today).day ?? 0) + 1,
            0
        )
        let currentWeekMetrics = Dictionary(uniqueKeysWithValues: metricsByDay.filter {
            $0.key >= weekInterval.start && $0.key < weekInterval.end
        })
        try upsertCurrentWeek(
            metrics: currentWeekMetrics,
            interval: weekInterval,
            expectedDays: min(weekDays, 7),
            target: target,
            in: modelContext
        )

        return WeeklyAnalyticsSnapshot(
            points: points,
            totalDeficitKcal: total.flatMap(Self.roundedInteger),
            averageDailyDeficitKcal: average,
            projectedWeightLossKg: projectedLoss,
            recordedDays: aggregate.coverage.availableDays,
            energyCoverage: aggregate.coverage
        )
    }

    private func upsertCurrentWeek(
        metrics: [Date: DailyMetricsReadResult],
        interval: DateInterval,
        expectedDays: Int,
        target: Int,
        in modelContext: ModelContext
    ) throws {
        let weekStart = calendar.startOfDay(for: interval.start)
        let predicate = #Predicate<WeeklyReport> { $0.weekStartDate == weekStart }
        var descriptor = FetchDescriptor<WeeklyReport>(predicate: predicate)
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first

        let rows = metrics.values.sorted { $0.date < $1.date }
        let energy = DailyMetricsUsabilityPolicy.aggregateSignedRanges(
            rows.map(\.deficit),
            expectedDays: expectedDays
        )
        let protein = DailyMetricsUsabilityPolicy.aggregateNumbers(
            rows.map(\.proteinG), expectedDays: expectedDays, average: true
        )
        let fat = DailyMetricsUsabilityPolicy.aggregateNumbers(
            rows.map(\.fatG), expectedDays: expectedDays, average: true
        )
        let carbs = DailyMetricsUsabilityPolicy.aggregateNumbers(
            rows.map(\.carbsG), expectedDays: expectedDays, average: true
        )

        // WeeklyReport has no availability fields in its persisted schema. Keep
        // it only when every elapsed day has complete energy and macro evidence;
        // the dashboard still shows partial results with explicit coverage.
        let complete = expectedDays > 0
            && energy.coverage.availableDays == expectedDays
            && protein.coverage.availableDays == expectedDays
            && fat.coverage.availableDays == expectedDays
            && carbs.coverage.availableDays == expectedDays
        guard complete,
              let totalDeficit = energy.total.value?.likely,
              let totalDeficitKcal = Self.roundedInteger(totalDeficit),
              let averageProtein = protein.total.value,
              let averageFat = fat.total.value,
              let averageCarbs = carbs.total.value else {
            if let existing {
                modelContext.delete(existing)
                try modelContext.save()
            }
            return
        }

        let report = existing ?? WeeklyReport(
            weekStartDate: weekStart,
            weekEndDate: interval.end.addingTimeInterval(-1)
        )
        if existing == nil { modelContext.insert(report) }
        let validRows = rows.filter { $0.deficit.value != nil }
        report.weekEndDate = interval.end.addingTimeInterval(-1)
        report.totalDeficitKcal = totalDeficitKcal
        report.avgDailyDeficitKcal = totalDeficit / Double(expectedDays)
        report.projectedWeightLossKg = totalDeficit / 7_700
        report.avgProteinG = averageProtein
        report.avgFatG = averageFat
        report.avgCarbsG = averageCarbs
        report.bestDay = validRows.max {
            ($0.deficit.value?.likely ?? -Double.infinity) < ($1.deficit.value?.likely ?? -Double.infinity)
        }?.date
        report.worstDay = validRows.min {
            ($0.deficit.value?.likely ?? Double.infinity) < ($1.deficit.value?.likely ?? Double.infinity)
        }?.date
        report.mealsCount = rows.reduce(0) { $0 + $1.mealCount }
        report.workoutsCount = rows.reduce(0) { $0 + $1.workoutCount }
        report.compliance = Double(validRows.filter { ($0.deficit.value?.likely ?? -Double.infinity) >= Double(target) }.count)
            / Double(expectedDays)
        report.generatedAt = Date()
        try modelContext.save()
    }

    private static func roundedInteger(_ value: Double) -> Int? {
        guard value.isFinite, value > Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value.rounded())
    }
}
