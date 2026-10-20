import Foundation

enum DailyBriefRefreshPolicy {
    static func shouldRefreshAfterActivation(
        initialRefreshCompleted: Bool,
        cachedBriefDayStart: Date?,
        lastSuccessfulRefreshDay: Date?,
        asOf date: Date,
        calendar: Calendar
    ) -> Bool {
        guard initialRefreshCompleted else { return false }
        if let cachedBriefDayStart,
           calendar.isDate(cachedBriefDayStart, inSameDayAs: date) {
            return false
        }
        if let lastSuccessfulRefreshDay,
           calendar.isDate(lastSuccessfulRefreshDay, inSameDayAs: date) {
            return false
        }
        return true
    }
}
