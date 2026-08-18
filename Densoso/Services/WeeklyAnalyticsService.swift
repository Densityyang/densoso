import Foundation
import SwiftData

struct WeeklyTrendPoint: Identifiable, Equatable {
    let date: Date
    let deficitKcal: Int
    let targetDeficitKcal: Int
    let hasData: Bool

    var id: Date { date }
}
struct WeeklyAnalyticsSnapshot: Equatable {
    let points: [WeeklyTrendPoint]
    let totalDeficitKcal: Int
    let averageDailyDeficitKcal: Double
    let projectedWeightLossKg: Double
    let recordedDays: Int

    var hasData: Bool { recordedDays > 0 }
}

/// Produces the dashboard's rolling seven-day series and keeps the current
/// calendar week's persisted report in sync with the same DailyMetrics source.
@MainActor
struct WeeklyAnalyticsService {
    var calendar: Calendar = .current

    func load(
        referenceDate: Date = Date(),
        profile: UserProfile?,
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
        let target = max(profile?.dailyDeficitTarget ?? 500, 0)

        var metricsByDay: [Date: DailyMetrics] = [:]
        for metric in metrics {
            metricsByDay[calendar.startOfDay(for: metric.date)] = metric
        }

        let points = (0..<7).compactMap { offset -> WeeklyTrendPoint? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: rollingStart) else { return nil }
            let metric = metricsByDay[date]
            return WeeklyTrendPoint(
                date: date,
                deficitKcal: metric?.deficitKcal ?? 0,
                targetDeficitKcal: target,
                hasData: metric != nil
            )
        }
        let recorded = points.filter(\.hasData)
        let totalDeficit = recorded.reduce(0) { $0 + $1.deficitKcal }
        let average = recorded.isEmpty ? 0 : Double(totalDeficit) / Double(recorded.count)

        try upsertCurrentWeek(
            metrics: metrics.filter { $0.date >= weekInterval.start && $0.date < weekInterval.end },
            interval: weekInterval,
            target: target,
            in: modelContext
        )

        return WeeklyAnalyticsSnapshot(
            points: points,
            totalDeficitKcal: totalDeficit,
            averageDailyDeficitKcal: average,
            projectedWeightLossKg: Double(totalDeficit) / 7_700,
            recordedDays: recorded.count
        )
    }

    private func upsertCurrentWeek(
        metrics: [DailyMetrics],
        interval: DateInterval,
        target: Int,
        in modelContext: ModelContext
    ) throws {
        let weekStart = calendar.startOfDay(for: interval.start)
        let predicate = #Predicate<WeeklyReport> { report in
            report.weekStartDate == weekStart
        }
        let existing = try modelContext.fetch(FetchDescriptor<WeeklyReport>(predicate: predicate)).first
        let report = existing ?? WeeklyReport(weekStartDate: weekStart, weekEndDate: interval.end.addingTimeInterval(-1))
        if existing == nil {
            modelContext.insert(report)
        }

        let count = metrics.count
        let totalDeficit = metrics.reduce(0) { $0 + $1.deficitKcal }
        report.weekEndDate = interval.end.addingTimeInterval(-1)
        report.totalDeficitKcal = totalDeficit
        report.avgDailyDeficitKcal = count == 0 ? 0 : Double(totalDeficit) / Double(count)
        report.projectedWeightLossKg = Double(totalDeficit) / 7_700
        report.avgProteinG = average(metrics.map(\.proteinG))
        report.avgFatG = average(metrics.map(\.fatG))
        report.avgCarbsG = average(metrics.map(\.carbsG))
        report.bestDay = metrics.max(by: { $0.deficitKcal < $1.deficitKcal })?.date
        report.worstDay = metrics.min(by: { $0.deficitKcal < $1.deficitKcal })?.date
        report.mealsCount = metrics.reduce(0) { $0 + $1.mealCount }
        report.workoutsCount = metrics.reduce(0) { $0 + $1.workoutCount }
        report.compliance = count == 0 ? 0 : Double(metrics.filter { $0.deficitKcal >= target }.count) / Double(count)
        report.generatedAt = Date()
        try modelContext.save()
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
