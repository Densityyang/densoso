import Foundation
import SwiftData

enum DailyMetricsWeightInvalidation {
    static func projectionDates(
        startingAt date: Date,
        searchingAfter searchDate: Date? = nil,
        excludingWeightID: UUID? = nil,
        in modelContext: ModelContext,
        calendar: Calendar = .current
    ) throws -> Set<Date> {
        let startDay = calendar.startOfDay(for: date)
        let effectiveSearchDate = searchDate ?? date
        let nextLocal = try LocalWeightObservationReader.firstObservation(
            after: effectiveSearchDate,
            excludingWeightID: excludingWeightID,
            in: modelContext
        )
        let nextHealthKit = try HealthKitWeightObservationReader.firstObservation(
            after: effectiveSearchDate,
            in: modelContext
        )
        let nextObservationDate = [nextLocal?.measuredAt, nextHealthKit?.measuredAt]
            .compactMap { $0 }
            .min()
        let boundaryDay = nextObservationDate.map { calendar.startOfDay(for: $0) }

        let predicate: Predicate<DailyMetrics>
        if let boundaryDay, boundaryDay > startDay {
            predicate = #Predicate<DailyMetrics> { $0.date >= startDay && $0.date < boundaryDay }
        } else if boundaryDay == startDay {
            predicate = #Predicate<DailyMetrics> { $0.date == startDay }
        } else {
            predicate = #Predicate<DailyMetrics> { $0.date >= startDay }
        }

        var dates = Set(try modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: predicate)).map {
            calendar.startOfDay(for: $0.date)
        })
        dates.insert(startDay)
        return dates
    }
}
