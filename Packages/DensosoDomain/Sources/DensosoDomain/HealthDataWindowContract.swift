import Foundation

/// Shared calendar-window requirements for health analysis and initial sync.
///
/// Keeping these values in the domain package lets the app's HealthKit sync
/// and domain-level health summaries use the same bounded-history contract.
public enum HealthDataWindowContract {
    /// Includes the target day and the preceding 41 calendar days.
    public static let analysisLookbackDays = 42

    /// Initial sync must populate at least the complete analysis window.
    public static let initialBackfillDays = 42

    /// Subjective check-ins use a separate, shorter history window.
    public static let subjectiveCheckInLookbackDays = 7

    /// Returns the start date for an inclusive, calendar-day window ending on
    /// `date`. Both the domain summary and HealthKit sync use this calculation.
    public static func startOfWindow(
        through date: Date,
        days: Int,
        calendar: Calendar
    ) -> Date? {
        guard days > 0 else { return nil }
        return calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: calendar.startOfDay(for: date)
        )
    }
}
