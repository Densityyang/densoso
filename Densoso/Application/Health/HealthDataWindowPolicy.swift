import Foundation
import DensosoDomain

/// Owns the bounded health-history windows shared by HealthKit sync and analysis.
struct HealthDataWindowPolicy: Sendable {
    static let analysisLookbackDays = 42
    static let initialBackfillDays = 42
    static let subjectiveCheckInLookbackDays = 7

    static func analysisStart(through date: Date, calendar: Calendar) -> Date? {
        startOfWindow(through: date, days: analysisLookbackDays, calendar: calendar)
    }

    static func initialBackfillStart(through date: Date, calendar: Calendar) -> Date? {
        startOfWindow(through: date, days: initialBackfillDays, calendar: calendar)
    }

    static func effectiveStart(
        policyStart: Date,
        authorizationStart: Date?
    ) -> Date {
        guard let authorizationStart else { return policyStart }
        return max(policyStart, authorizationStart)
    }

    /// Returns the first daily projection whose complete read window starts at
    /// or after HealthKit's limited-history boundary. Sleep is keyed by wake
    /// day and reads from 18:00 on the previous day.
    static func firstFullyAuthorizedDay(
        for metric: HealthMetricID,
        authorizationStart: Date,
        calendar: Calendar
    ) -> Date {
        let boundaryDay = calendar.startOfDay(for: authorizationStart)
        if metric == .sleepAnalysis {
            guard let sleepWindowStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: boundaryDay),
                  let firstWakeDay = calendar.date(byAdding: .day, value: 1, to: boundaryDay) else {
                return calendar.date(byAdding: .day, value: 2, to: boundaryDay) ?? boundaryDay
            }
            if authorizationStart <= sleepWindowStart { return firstWakeDay }
            return calendar.date(byAdding: .day, value: 2, to: boundaryDay) ?? firstWakeDay
        }

        guard authorizationStart == boundaryDay else {
            return calendar.date(byAdding: .day, value: 1, to: boundaryDay) ?? boundaryDay
        }
        return boundaryDay
    }

    /// Anchored queries keep their original predicate. Rebaseline only when the
    /// existing cursor cannot satisfy the new bounded window or crosses a new
    /// HealthKit authorization boundary.
    static func requiresRebaseline(
        cursorStart: Date?,
        policyStart: Date,
        authorizationStart: Date?
    ) -> Bool {
        guard let cursorStart else { return false }
        let effectiveStart = max(policyStart, authorizationStart ?? policyStart)
        if cursorStart > effectiveStart { return true }
        if let authorizationStart, cursorStart < authorizationStart { return true }
        return false
    }

    static func days(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last,
              let count = calendar.dateComponents([.day], from: first, to: last).day,
              count >= 0 else { return [] }
        return (0...count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    private static func startOfWindow(through date: Date, days: Int, calendar: Calendar) -> Date? {
        guard days > 0 else { return nil }
        return calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: calendar.startOfDay(for: date)
        )
    }
}

/// Optional app-layer capability: older and fake clients can omit a limited
/// history boundary, while the HealthKit adapter reports one when configured.
protocol HealthAuthorizationBoundaryProviding: Sendable {
    func earliestAuthorizedSampleDate(for metric: HealthMetricID) async throws -> Date?
}
