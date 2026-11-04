import Foundation

enum DailyBriefRefreshPolicy {
    static let defaultValidationInterval: TimeInterval = 6 * 60 * 60

    static func shouldRefreshAfterActivation(
        initialRefreshCompleted: Bool,
        cachedBriefDayStart: Date?,
        validatedAt: Date?,
        lastSuccessfulAt: Date? = nil,
        lastFailedAt: Date? = nil,
        consecutiveFailures: Int = 0,
        sourceFingerprintChanged: Bool = false,
        asOf date: Date,
        calendar: Calendar,
        validationInterval: TimeInterval = defaultValidationInterval
    ) -> Bool {
        guard initialRefreshCompleted else { return false }
        if let lastFailedAt {
            let retryAfter = retryBackoffInterval(failureCount: consecutiveFailures)
            guard date.timeIntervalSince(lastFailedAt) >= retryAfter else { return false }
            return true
        }
        if let cachedBriefDayStart {
            guard calendar.isDate(cachedBriefDayStart, inSameDayAs: date) else { return true }
            guard let validatedAt else { return true }
            return sourceFingerprintChanged || date.timeIntervalSince(validatedAt) >= validationInterval
        }
        if sourceFingerprintChanged { return true }
        guard let lastSuccessfulAt else { return true }
        guard calendar.isDate(lastSuccessfulAt, inSameDayAs: date) else { return true }
        return date.timeIntervalSince(lastSuccessfulAt) >= validationInterval
    }

    static func retryBackoffInterval(failureCount: Int) -> TimeInterval {
        let exponent = min(max(failureCount - 1, 0), 5)
        return TimeInterval(min(30 * (1 << exponent), 15 * 60))
    }
}
