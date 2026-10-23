import Foundation

/// Time-of-day phase selected by the application for the current local day.
public enum DailyLoopPhase: String, Codable, CaseIterable, Sendable {
    case morning
    case daytime
    case evening
}

/// Semantic shortcuts that a client may offer from the daily loop.
public enum DailyLoopQuickAction: String, Codable, CaseIterable, Sendable {
    case logMeal
    case logWeight
    case planWorkout
    case dailyCheckIn
}

public enum DailyLoopRefreshState: String, Codable, CaseIterable, Sendable {
    case fresh
    case stale
    case refreshRequired
    case error
}

public struct DailyLoopMetricCoverage: Codable, Equatable, Sendable {
    public let intake: MetricAvailability
    public let expenditure: MetricAvailability
    public let deficit: MetricAvailability
    public let proteinG: MetricAvailability
    public let fatG: MetricAvailability
    public let carbsG: MetricAvailability

    public init(
        intake: MetricAvailability,
        expenditure: MetricAvailability,
        deficit: MetricAvailability,
        proteinG: MetricAvailability,
        fatG: MetricAvailability,
        carbsG: MetricAvailability
    ) {
        self.intake = intake
        self.expenditure = expenditure
        self.deficit = deficit
        self.proteinG = proteinG
        self.fatG = fatG
        self.carbsG = carbsG
    }

    public static let unavailable = DailyLoopMetricCoverage(
        intake: .unavailable,
        expenditure: .unavailable,
        deficit: .unavailable,
        proteinG: .unavailable,
        fatG: .unavailable,
        carbsG: .unavailable
    )
}

/// A short presentation summary paired with the existing computed health state.
/// This type stores supplied values only; health calculations remain in their service.
public struct DailyStateSummary: Codable, Equatable, Sendable {
    public let headline: String
    public let detail: String?
    public let healthState: HealthStateV2?

    public init(headline: String, detail: String? = nil, healthState: HealthStateV2? = nil) {
        self.headline = headline
        self.detail = detail
        self.healthState = healthState
    }
}

/// Current-day view contract composed from already available domain summaries.
/// `dayStart` and `dayKey` identify the caller's local-calendar day, while
/// `generatedAt` records when this composition was produced. This value does not
/// infer phases, guidance, or health state.
public struct DailyLoopSnapshot: Codable, Equatable, Sendable {
    public static let currentAlgorithmVersion = AlgorithmVersions.dailyLoop
    public static let legacyProjectionVersion = "legacy-unknown"

    public let dayStart: Date
    public let dayKey: String
    public let timezoneIdentifier: String
    public let generatedAt: Date
    public let sourceFingerprint: String?
    public let projectionVersion: String
    public let coverage: DailyLoopMetricCoverage
    public let refreshState: DailyLoopRefreshState
    public let errorCode: String?
    public let phase: DailyLoopPhase
    public let todayState: DailyStateSummary?
    public let todaySummary: String?
    public let tomorrowGuidance: NextDayGuidance?
    public let pendingActions: [WatchPendingActionSummary]
    public let workoutPlans: [WatchWorkoutPlanSummary]
    public let quickActions: [DailyLoopQuickAction]

    public init(
        dayStart: Date,
        dayKey: String? = nil,
        timezoneIdentifier: String = TimeZone.current.identifier,
        generatedAt: Date = Date(),
        sourceFingerprint: String? = nil,
        projectionVersion: String = AlgorithmVersions.dailyLoop,
        coverage: DailyLoopMetricCoverage = .unavailable,
        refreshState: DailyLoopRefreshState = .refreshRequired,
        errorCode: String? = nil,
        phase: DailyLoopPhase,
        todayState: DailyStateSummary? = nil,
        todaySummary: String? = nil,
        tomorrowGuidance: NextDayGuidance? = nil,
        pendingActions: [WatchPendingActionSummary] = [],
        workoutPlans: [WatchWorkoutPlanSummary] = [],
        quickActions: [DailyLoopQuickAction] = []
    ) {
        self.dayStart = dayStart
        let resolvedTimeZone = TimeZone(identifier: timezoneIdentifier) == nil ? "unknown" : timezoneIdentifier
        self.dayKey = dayKey ?? (
            resolvedTimeZone == "unknown"
                ? "unknown"
                : Self.localDayKey(for: dayStart, timezoneIdentifier: resolvedTimeZone)
        )
        self.timezoneIdentifier = resolvedTimeZone
        self.generatedAt = generatedAt
        self.sourceFingerprint = sourceFingerprint
        self.projectionVersion = projectionVersion
        self.coverage = coverage
        self.refreshState = refreshState
        self.errorCode = errorCode.map { String($0.prefix(80)) }
        self.phase = phase
        self.todayState = todayState
        self.todaySummary = todaySummary
        self.tomorrowGuidance = tomorrowGuidance
        self.pendingActions = pendingActions
        self.workoutPlans = workoutPlans
        self.quickActions = quickActions
    }

    private enum CodingKeys: String, CodingKey {
        case dayStart
        case dayKey
        case timezoneIdentifier
        case generatedAt
        case sourceFingerprint
        case projectionVersion
        case coverage
        case refreshState
        case errorCode
        case phase
        case todayState
        case todaySummary
        case tomorrowGuidance
        case pendingActions
        case workoutPlans
        case quickActions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let dayStart = try values.decode(Date.self, forKey: .dayStart)
        let decodedTimeZone = try values.decodeIfPresent(String.self, forKey: .timezoneIdentifier)
        let timezoneIdentifier: String
        if let decodedTimeZone, TimeZone(identifier: decodedTimeZone) != nil {
            timezoneIdentifier = decodedTimeZone
        } else {
            timezoneIdentifier = "unknown"
        }
        let dayKey = try values.decodeIfPresent(String.self, forKey: .dayKey)
            ?? (timezoneIdentifier == "unknown"
                ? "unknown"
                : Self.localDayKey(for: dayStart, timezoneIdentifier: timezoneIdentifier))
        self.init(
            dayStart: dayStart,
            dayKey: dayKey,
            timezoneIdentifier: timezoneIdentifier,
            generatedAt: try values.decodeIfPresent(Date.self, forKey: .generatedAt) ?? dayStart,
            sourceFingerprint: try values.decodeIfPresent(String.self, forKey: .sourceFingerprint),
            projectionVersion: try values.decodeIfPresent(String.self, forKey: .projectionVersion)
                ?? Self.legacyProjectionVersion,
            coverage: try values.decodeIfPresent(DailyLoopMetricCoverage.self, forKey: .coverage)
                ?? .unavailable,
            refreshState: try values.decodeIfPresent(DailyLoopRefreshState.self, forKey: .refreshState)
                ?? .refreshRequired,
            errorCode: try values.decodeIfPresent(String.self, forKey: .errorCode),
            phase: try values.decode(DailyLoopPhase.self, forKey: .phase),
            todayState: try values.decodeIfPresent(DailyStateSummary.self, forKey: .todayState),
            todaySummary: try values.decodeIfPresent(String.self, forKey: .todaySummary),
            tomorrowGuidance: try values.decodeIfPresent(NextDayGuidance.self, forKey: .tomorrowGuidance),
            pendingActions: try values.decodeIfPresent([WatchPendingActionSummary].self, forKey: .pendingActions) ?? [],
            workoutPlans: try values.decodeIfPresent([WatchWorkoutPlanSummary].self, forKey: .workoutPlans) ?? [],
            quickActions: try values.decodeIfPresent([DailyLoopQuickAction].self, forKey: .quickActions) ?? []
        )
    }

    public static func localDayKey(for date: Date, timezoneIdentifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneIdentifier) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
