import Foundation

public enum HealthDomain: String, Codable, CaseIterable, Sendable {
    case nutrition
    case sleep
    case activity
    case body
}

public enum HealthDomainStatus: String, Codable, CaseIterable, Sendable {
    case noData
    case learning
    case withinTypicalRange
    case changed
    case attention
}

public enum BaselineReadiness: String, Codable, CaseIterable, Sendable {
    case noData
    case learning
    case temporary
    case mature
}

public struct HealthBaseline: Codable, Equatable, Sendable {
    public let readiness: BaselineReadiness
    public let validDays: Int
    public let median: Double?
    public let p10: Double?
    public let p90: Double?
    public let mad: Double?

    public init(
        readiness: BaselineReadiness,
        validDays: Int,
        median: Double?,
        p10: Double?,
        p90: Double?,
        mad: Double?
    ) {
        self.readiness = readiness
        self.validDays = validDays
        self.median = median
        self.p10 = p10
        self.p90 = p90
        self.mad = mad
    }

    public func robustZScore(for value: Double) -> Double? {
        guard value.isFinite, let median, let mad, mad.isFinite, mad > 1e-9 else { return nil }
        let score = 0.6745 * (value - median) / mad
        return score.isFinite ? score : nil
    }

    public func isSignificantChange(_ value: Double) -> Bool {
        guard readiness != .noData,
              let p10, let p90,
              let robustZ = robustZScore(for: value) else { return false }
        return (value < p10 || value > p90) && abs(robustZ) >= 2.5
    }
}

public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case inBed
    case awake
    case asleepCore
    case asleepDeep
    case asleepREM
    case asleepUnspecified
    case unknown

    public var isAsleep: Bool {
        switch self {
        case .asleepCore, .asleepDeep, .asleepREM, .asleepUnspecified: true
        case .inBed, .awake, .unknown: false
        }
    }
}

public struct SleepSampleInterval: Codable, Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date
    public let stage: SleepStage
    public let sourceBundleIdentifier: String?
    public let deviceModel: String?

    public init(
        startDate: Date,
        endDate: Date,
        stage: SleepStage,
        sourceBundleIdentifier: String? = nil,
        deviceModel: String? = nil
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.stage = stage
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.deviceModel = deviceModel
    }

    public var durationMinutes: Double {
        max(endDate.timeIntervalSince(startDate), 0) / 60
    }

    public var isAppleWatchSample: Bool {
        let source = sourceBundleIdentifier?.lowercased() ?? ""
        let device = deviceModel?.lowercased() ?? ""
        return source.contains("watch") || device.contains("watch")
    }
}

public struct SleepStageMinutes: Codable, Equatable, Sendable {
    public let core: Double
    public let deep: Double
    public let rem: Double

    public init(core: Double, deep: Double, rem: Double) {
        self.core = core
        self.deep = deep
        self.rem = rem
    }
}

public struct SleepSummary: Codable, Equatable, Sendable {
    public let wakeDate: Date
    public let totalAsleepMinutes: Double
    public let mainSleepMinutes: Double?
    public let napMinutes: Double
    public let stageCoverage: Double?
    public let stages: SleepStageMinutes?
    public let selectedSourceBundleIdentifier: String?

    public init(
        wakeDate: Date,
        totalAsleepMinutes: Double,
        mainSleepMinutes: Double?,
        napMinutes: Double,
        stageCoverage: Double?,
        stages: SleepStageMinutes?,
        selectedSourceBundleIdentifier: String?
    ) {
        self.wakeDate = wakeDate
        self.totalAsleepMinutes = totalAsleepMinutes
        self.mainSleepMinutes = mainSleepMinutes
        self.napMinutes = napMinutes
        self.stageCoverage = stageCoverage
        self.stages = stages
        self.selectedSourceBundleIdentifier = selectedSourceBundleIdentifier
    }
}

public struct TrainingWorkoutInput: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let durationMinutes: Double
    public let effortScore: Double?
    public let intensity: String?

    public init(startedAt: Date, durationMinutes: Double, effortScore: Double? = nil, intensity: String? = nil) {
        self.startedAt = startedAt
        self.durationMinutes = durationMinutes
        self.effortScore = effortScore
        self.intensity = intensity
    }
}

public enum TrainingLoadBand: String, Codable, CaseIterable, Sendable {
    case unavailable
    case learning
    case belowTypical
    case gradualReturn
    case nearTypical
    case increased
    case sharplyIncreased
}

public struct TrainingLoadSummary: Codable, Equatable, Sendable {
    public let recentSevenDayLoad: Double
    public let priorTwentyEightDayAverage: Double?
    public let ratio: Double?
    public let readiness: BaselineReadiness
    public let band: TrainingLoadBand
    public let estimatedWorkoutCount: Int
    public let unavailableEffortCount: Int

    public init(
        recentSevenDayLoad: Double,
        priorTwentyEightDayAverage: Double?,
        ratio: Double?,
        readiness: BaselineReadiness,
        band: TrainingLoadBand,
        estimatedWorkoutCount: Int,
        unavailableEffortCount: Int
    ) {
        self.recentSevenDayLoad = recentSevenDayLoad
        self.priorTwentyEightDayAverage = priorTwentyEightDayAverage
        self.ratio = ratio
        self.readiness = readiness
        self.band = band
        self.estimatedWorkoutCount = estimatedWorkoutCount
        self.unavailableEffortCount = unavailableEffortCount
    }
}

public struct HealthIntelligenceDay: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let energyIntakeKcal: Double?
    public let proteinGrams: Double?
    public let dailyDeficitKcal: Double?
    public let activeEnergyKcal: Double?
    public let stepCount: Double?
    public let exerciseMinutes: Double?
    public let weightSamplesKilograms: [Double]
    public let sleepSamples: [SleepSampleInterval]
    public let heartRateSamples: [Double]
    public let restingHeartRateSamples: [Double]
    public let heartRateVariabilitySamples: [Double]
    public let respiratoryRateSamples: [Double]
    public let wristTemperatureSamples: [Double]
    public let workouts: [TrainingWorkoutInput]

    public init(
        dayStart: Date,
        energyIntakeKcal: Double? = nil,
        proteinGrams: Double? = nil,
        dailyDeficitKcal: Double? = nil,
        activeEnergyKcal: Double? = nil,
        stepCount: Double? = nil,
        exerciseMinutes: Double? = nil,
        weightSamplesKilograms: [Double] = [],
        sleepSamples: [SleepSampleInterval] = [],
        heartRateSamples: [Double] = [],
        restingHeartRateSamples: [Double] = [],
        heartRateVariabilitySamples: [Double] = [],
        respiratoryRateSamples: [Double] = [],
        wristTemperatureSamples: [Double] = [],
        workouts: [TrainingWorkoutInput] = []
    ) {
        self.dayStart = dayStart
        self.energyIntakeKcal = Self.valid(energyIntakeKcal)
        self.proteinGrams = Self.valid(proteinGrams)
        self.dailyDeficitKcal = Self.valid(dailyDeficitKcal)
        self.activeEnergyKcal = Self.valid(activeEnergyKcal)
        self.stepCount = Self.valid(stepCount)
        self.exerciseMinutes = Self.valid(exerciseMinutes)
        self.weightSamplesKilograms = weightSamplesKilograms.filter { $0.isFinite && $0 > 0 }
        self.sleepSamples = sleepSamples
        self.heartRateSamples = heartRateSamples.filter { $0.isFinite && $0 > 0 }
        self.restingHeartRateSamples = restingHeartRateSamples.filter { $0.isFinite && $0 > 0 }
        self.heartRateVariabilitySamples = heartRateVariabilitySamples.filter { $0.isFinite && $0 > 0 }
        self.respiratoryRateSamples = respiratoryRateSamples.filter { $0.isFinite && $0 > 0 }
        self.wristTemperatureSamples = wristTemperatureSamples.filter(\.isFinite)
        self.workouts = workouts
    }

    private static func valid(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

public struct HealthDomainResult: Codable, Equatable, Sendable, Identifiable {
    public let domain: HealthDomain
    public let status: HealthDomainStatus
    public let currentValue: Double?
    public let baseline: HealthBaseline
    public let evidenceKeys: [String]

    public var id: HealthDomain { domain }

    public init(
        domain: HealthDomain,
        status: HealthDomainStatus,
        currentValue: Double?,
        baseline: HealthBaseline,
        evidenceKeys: [String]
    ) {
        self.domain = domain
        self.status = status
        self.currentValue = currentValue
        self.baseline = baseline
        self.evidenceKeys = evidenceKeys
    }
}

public struct HealthRecommendation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let domain: HealthDomain
    public let title: String
    public let detail: String
    public let evidenceKey: String
    public let conflictGroup: String
    public let score: Double

    public init(
        id: String,
        domain: HealthDomain,
        title: String,
        detail: String,
        evidenceKey: String,
        conflictGroup: String,
        score: Double
    ) {
        self.id = id
        self.domain = domain
        self.title = title
        self.detail = detail
        self.evidenceKey = evidenceKey
        self.conflictGroup = conflictGroup
        self.score = score
    }
}

public struct HealthContextWindowSummary: Codable, Equatable, Sendable {
    public let windowDays: Int
    public let coverageDays: [String: Int]
    public let averageSleepMinutes: Double?
    public let averageStepCount: Double?
    public let averageActiveEnergyKcal: Double?
    public let averageEnergyIntakeKcal: Double?
    public let averageDailyDeficitKcal: Double?
    public let averageProteinGrams: Double?
    public let medianWeightKilograms: Double?

    public init(
        windowDays: Int,
        coverageDays: [String: Int],
        averageSleepMinutes: Double?,
        averageStepCount: Double?,
        averageActiveEnergyKcal: Double?,
        averageEnergyIntakeKcal: Double?,
        averageDailyDeficitKcal: Double?,
        averageProteinGrams: Double?,
        medianWeightKilograms: Double?
    ) {
        self.windowDays = min(max(windowDays, 1), 28)
        self.coverageDays = coverageDays.mapValues { max($0, 0) }
        self.averageSleepMinutes = Self.valid(averageSleepMinutes)
        self.averageStepCount = Self.valid(averageStepCount)
        self.averageActiveEnergyKcal = Self.valid(averageActiveEnergyKcal)
        self.averageEnergyIntakeKcal = Self.valid(averageEnergyIntakeKcal)
        self.averageDailyDeficitKcal = averageDailyDeficitKcal.flatMap { $0.isFinite ? $0 : nil }
        self.averageProteinGrams = Self.valid(averageProteinGrams)
        self.medianWeightKilograms = Self.valid(medianWeightKilograms)
    }

    private static func valid(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

/// This summary is the only health-context shape intended for a cloud provider.
/// It contains 7/28-day aggregates, coverage and references, never raw samples or daily rows.
public struct HealthContextSummary: Codable, Equatable, Sendable {
    public let sevenDay: HealthContextWindowSummary
    public let twentyEightDay: HealthContextWindowSummary
    public let targetWeightKilograms: Double?
    public let dailyDeficitGoalKcal: Int?
    public let dailyProteinGoalGrams: Double?
    public let recommendationReferences: [String]

    public init(
        sevenDay: HealthContextWindowSummary,
        twentyEightDay: HealthContextWindowSummary,
        targetWeightKilograms: Double?,
        dailyDeficitGoalKcal: Int?,
        dailyProteinGoalGrams: Double?,
        recommendationReferences: [String]
    ) {
        self.sevenDay = sevenDay
        self.twentyEightDay = twentyEightDay
        self.targetWeightKilograms = targetWeightKilograms.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.dailyDeficitGoalKcal = dailyDeficitGoalKcal.map { max($0, 0) }
        self.dailyProteinGoalGrams = dailyProteinGoalGrams.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.recommendationReferences = Array(Set(recommendationReferences)).sorted()
    }
}

public enum HealthVitalMetric: String, Codable, CaseIterable, Sendable {
    case restingHeartRate
    case heartRateVariability
    case respiratoryRate
    case wristTemperature
    case bodyWeight
}

public struct HealthVitalTrend: Codable, Equatable, Sendable, Identifiable {
    public let metric: HealthVitalMetric
    public let latestMedian: Double?
    public let baseline: HealthBaseline
    public let status: HealthDomainStatus
    public let evidenceKey: String

    public var id: HealthVitalMetric { metric }

    public init(
        metric: HealthVitalMetric,
        latestMedian: Double?,
        baseline: HealthBaseline,
        status: HealthDomainStatus,
        evidenceKey: String
    ) {
        self.metric = metric
        self.latestMedian = latestMedian
        self.baseline = baseline
        self.status = status
        self.evidenceKey = evidenceKey
    }
}

public struct DailyHealthBrief: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let summary: String
    public let domains: [HealthDomainResult]
    public let recommendations: [HealthRecommendation]
    public let sleep: SleepSummary?
    public let vitalTrends: [HealthVitalTrend]
    public let trainingLoad: TrainingLoadSummary
    public let contextSummary: HealthContextSummary
    public let algorithmVersion: String
    public let healthState: HealthStateV2?

    public init(
        dayStart: Date,
        summary: String,
        domains: [HealthDomainResult],
        recommendations: [HealthRecommendation],
        sleep: SleepSummary?,
        vitalTrends: [HealthVitalTrend],
        trainingLoad: TrainingLoadSummary,
        contextSummary: HealthContextSummary,
        algorithmVersion: String,
        healthState: HealthStateV2? = nil
    ) {
        self.dayStart = dayStart
        self.summary = summary
        self.domains = domains
        self.recommendations = Array(recommendations.prefix(2))
        self.sleep = sleep
        self.vitalTrends = vitalTrends
        self.trainingLoad = trainingLoad
        self.contextSummary = contextSummary
        self.algorithmVersion = algorithmVersion
        self.healthState = healthState
    }
}

public struct WeeklyHealthBrief: Codable, Equatable, Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    public let daysWithData: Int
    public let averageSleepMinutes: Double?
    public let averageEnergyIntakeKcal: Double?
    public let medianWeightKilograms: Double?
    public let trainingLoad: TrainingLoadSummary
    public let domainStatuses: [HealthDomainResult]
    public let summary: String
    public let algorithmVersion: String

    public init(
        weekStart: Date,
        weekEnd: Date,
        daysWithData: Int,
        averageSleepMinutes: Double?,
        averageEnergyIntakeKcal: Double?,
        medianWeightKilograms: Double?,
        trainingLoad: TrainingLoadSummary,
        domainStatuses: [HealthDomainResult],
        summary: String,
        algorithmVersion: String
    ) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.daysWithData = min(max(daysWithData, 0), 7)
        self.averageSleepMinutes = averageSleepMinutes
        self.averageEnergyIntakeKcal = averageEnergyIntakeKcal
        self.medianWeightKilograms = medianWeightKilograms
        self.trainingLoad = trainingLoad
        self.domainStatuses = domainStatuses
        self.summary = summary
        self.algorithmVersion = algorithmVersion
    }
}

public struct HealthIntelligenceResult: Codable, Equatable, Sendable {
    public let dailyBrief: DailyHealthBrief
    public let weightTrendKilograms: Double?
    public let previousWeightMedianKilograms: Double?

    public init(
        dailyBrief: DailyHealthBrief,
        weightTrendKilograms: Double?,
        previousWeightMedianKilograms: Double?
    ) {
        self.dailyBrief = dailyBrief
        self.weightTrendKilograms = weightTrendKilograms
        self.previousWeightMedianKilograms = previousWeightMedianKilograms
    }
}

public struct HealthIntelligenceEngine: Sendable {
    public static let algorithmVersion = "health-intelligence-v2"
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func baseline(for values: [(date: Date, value: Double)], before date: Date) -> HealthBaseline {
        let targetDay = calendar.startOfDay(for: date)
        var latestByDay: [Date: Double] = [:]
        for point in values where point.value.isFinite {
            let day = calendar.startOfDay(for: point.date)
            guard day < targetDay else { continue }
            latestByDay[day] = point.value
        }
        let ordered = latestByDay.sorted { $0.key < $1.key }.suffix(28).map { $0.value }
        let readiness: BaselineReadiness
        switch ordered.count {
        case 0: readiness = .noData
        case 1..<7: readiness = .learning
        case 7..<28: readiness = .temporary
        default: readiness = .mature
        }
        guard !ordered.isEmpty else {
            return HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
        }
        let middle = Self.median(ordered)
        let deviations = ordered.map { abs($0 - middle) }
        return HealthBaseline(
            readiness: readiness,
            validDays: ordered.count,
            median: middle,
            p10: Self.percentile(ordered, 0.10),
            p90: Self.percentile(ordered, 0.90),
            mad: Self.median(deviations)
        )
    }

    public func sleepSummary(for wakeDate: Date, samples: [SleepSampleInterval]) -> SleepSummary? {
        let wakeDay = calendar.startOfDay(for: wakeDate)
        guard let previousDay = calendar.date(byAdding: .day, value: -1, to: wakeDay),
              let windowStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay),
              let windowEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: wakeDay) else { return nil }

        let valid = samples.filter { $0.stage.isAsleep && $0.endDate > $0.startDate }
        guard !valid.isEmpty else { return nil }
        let appleWatchSamples = valid.filter {
            $0.isAppleWatchSample && $0.endDate > windowStart && $0.startDate < windowEnd
        }
        let selectedSource: String?
        let clipped: [(start: Date, end: Date, stage: SleepStage)]
        func sourceKey(_ sample: SleepSampleInterval) -> String {
            if let bundle = sample.sourceBundleIdentifier, !bundle.isEmpty { return bundle }
            if let model = sample.deviceModel, !model.isEmpty { return "device:\(model)" }
            return "unknown"
        }
        func clip(_ samples: [SleepSampleInterval]) -> [(start: Date, end: Date, stage: SleepStage)] {
            samples.compactMap { sample in
                let start = max(sample.startDate, windowStart)
                let end = min(sample.endDate, windowEnd)
                guard end > start else { return nil }
                return (start, end, sample.stage)
            }
        }
        if !appleWatchSamples.isEmpty {
            let watchGroups = Dictionary(grouping: appleWatchSamples, by: sourceKey)
            let rankedWatchSources = watchGroups.sorted { lhs, rhs in
                let lhsDuration = Self.unionDuration(lhs.value, start: windowStart, end: windowEnd)
                let rhsDuration = Self.unionDuration(rhs.value, start: windowStart, end: windowEnd)
                return lhsDuration == rhsDuration ? lhs.key < rhs.key : lhsDuration > rhsDuration
            }
            var watchIntervals: [(start: Date, end: Date, stage: SleepStage)] = []
            var coveredIntervals: [(Date, Date)] = []
            for (index, source) in rankedWatchSources.enumerated() {
                let sourceIntervals = clip(source.value)
                let uniqueIntervals = index == 0
                    ? sourceIntervals
                    : sourceIntervals.flatMap { interval in
                        Self.subtract((interval.start, interval.end), coveredBy: coveredIntervals).map {
                            (start: $0.0, end: $0.1, stage: interval.stage)
                        }
                    }
                watchIntervals.append(contentsOf: uniqueIntervals)
                coveredIntervals = Self.merge(coveredIntervals + uniqueIntervals.map { ($0.start, $0.end) })
            }
            let selectedWatchSource = rankedWatchSources.first?.value.first?.sourceBundleIdentifier
            let nonWatchGroups = Dictionary(grouping: valid.filter { !$0.isAppleWatchSample }, by: sourceKey)
            let rankedNonWatchSources = nonWatchGroups.sorted { lhs, rhs in
                let lhsDuration = Self.unionDuration(lhs.value, start: windowStart, end: windowEnd)
                let rhsDuration = Self.unionDuration(rhs.value, start: windowStart, end: windowEnd)
                return lhsDuration == rhsDuration ? lhs.key < rhs.key : lhsDuration > rhsDuration
            }
            var supplemental: [(start: Date, end: Date, stage: SleepStage)] = []
            for (_, sourceSamples) in rankedNonWatchSources {
                let uniqueIntervals = clip(sourceSamples).flatMap { interval in
                    Self.subtract((interval.start, interval.end), coveredBy: coveredIntervals).map {
                        (start: $0.0, end: $0.1, stage: interval.stage)
                    }
                }
                supplemental.append(contentsOf: uniqueIntervals)
                coveredIntervals = Self.merge(coveredIntervals + uniqueIntervals.map { ($0.start, $0.end) })
            }
            // Prefer one Watch source on overlap and one best non-Watch source
            // per uncovered interval; this preserves unique segments without
            // double-counting cross-source stages.
            clipped = watchIntervals + supplemental
            selectedSource = selectedWatchSource
        } else {
            let bySource = Dictionary(grouping: valid, by: sourceKey)
            let winner = bySource.sorted { lhs, rhs in
                let lhsDuration = Self.unionDuration(lhs.value, start: windowStart, end: windowEnd)
                let rhsDuration = Self.unionDuration(rhs.value, start: windowStart, end: windowEnd)
                return lhsDuration == rhsDuration ? lhs.key < rhs.key : lhsDuration < rhsDuration
            }.last
            selectedSource = winner?.value.first?.sourceBundleIdentifier
            clipped = clip(winner?.value ?? [])
        }

        let asleepIntervals = Self.merge(clipped.map { ($0.start, $0.end) })
        guard !asleepIntervals.isEmpty else { return nil }
        let sleepMinutes = asleepIntervals.reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 60
        let main = asleepIntervals.max { $0.1.timeIntervalSince($0.0) < $1.1.timeIntervalSince($1.0) }
        let mainMinutes = main.map { $0.1.timeIntervalSince($0.0) / 60 }
        let naps = max(sleepMinutes - (mainMinutes ?? 0), 0)

        guard let main, let mainMinutes, mainMinutes >= 90 else {
            return SleepSummary(
                wakeDate: wakeDay,
                totalAsleepMinutes: sleepMinutes,
                mainSleepMinutes: nil,
                napMinutes: sleepMinutes,
                stageCoverage: nil,
                stages: nil,
                selectedSourceBundleIdentifier: selectedSource
            )
        }
        let mainStageIntervals = clipped.filter { $0.start < main.1 && $0.end > main.0 }
        let stageIntervals: [SleepStage: [(Date, Date)]] = Dictionary(grouping: mainStageIntervals, by: { $0.stage })
            .mapValues { values in Self.merge(values.map { (max($0.start, main.0), min($0.end, main.1)) }) }
        func minutes(_ stage: SleepStage) -> Double {
            (stageIntervals[stage] ?? []).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) } / 60
        }
        let core = minutes(.asleepCore)
        let deep = minutes(.asleepDeep)
        let rem = minutes(.asleepREM)
        let stagedMinutes = min(core + deep + rem, mainMinutes)
        let coverage = mainMinutes > 0 ? stagedMinutes / mainMinutes : 0
        let visibleStages = coverage >= 0.60 ? SleepStageMinutes(core: core, deep: deep, rem: rem) : nil
        return SleepSummary(
            wakeDate: wakeDay,
            totalAsleepMinutes: sleepMinutes,
            mainSleepMinutes: mainMinutes,
            napMinutes: naps,
            stageCoverage: coverage,
            stages: visibleStages,
            selectedSourceBundleIdentifier: selectedSource
        )
    }

    public func trainingLoad(workouts: [TrainingWorkoutInput], asOf date: Date) -> TrainingLoadSummary {
        let today = calendar.startOfDay(for: date)
        guard let recentStart = calendar.date(byAdding: .day, value: -6, to: today),
              let baselineStart = calendar.date(byAdding: .day, value: -34, to: today) else {
            return TrainingLoadSummary(
                recentSevenDayLoad: 0, priorTwentyEightDayAverage: nil, ratio: nil,
                readiness: .noData, band: .unavailable, estimatedWorkoutCount: 0, unavailableEffortCount: 0
            )
        }
        var dailyLoads: [Date: Double] = [:]
        var unknownEffortDays = Set<Date>()
        var estimated = 0
        var unavailable = 0
        for workout in workouts {
            let day = calendar.startOfDay(for: workout.startedAt)
            guard day >= baselineStart && day <= today,
                  workout.durationMinutes.isFinite,
                  workout.durationMinutes > 0 else { continue }
            let effort: Double
            if let measured = workout.effortScore, measured.isFinite, (0...10).contains(measured), measured > 0 {
                effort = measured
            } else if let mapped = Self.estimatedEffort(for: workout.intensity) {
                effort = mapped
                estimated += 1
            } else {
                unavailable += 1
                unknownEffortDays.insert(day)
                continue
            }
            dailyLoads[day, default: 0] += workout.durationMinutes * effort
        }

        let recent = dailyLoads.filter {
            $0.key >= recentStart && $0.key <= today && !unknownEffortDays.contains($0.key)
        }
            .values.reduce(0, +)
        // Count days with effort-known sessions toward sample maturity, but
        // divide load across the full four-week calendar window so rest days
        // contribute zero instead of requiring a workout every day.
        let priorDays = Set(dailyLoads.keys.filter {
            $0 >= baselineStart && $0 < recentStart && !unknownEffortDays.contains($0)
        })
        let validDays = priorDays.count
        let priorTotal = priorDays.reduce(0) { $0 + (dailyLoads[$1] ?? 0) }
        let hasUnknownEffortInPriorWindow = unknownEffortDays.contains {
            $0 >= baselineStart && $0 < recentStart
        }
        let hasUnknownEffortInRecentWindow = unknownEffortDays.contains {
            $0 >= recentStart && $0 <= today
        }
        let priorAverage = validDays == 0 || hasUnknownEffortInPriorWindow ? nil : priorTotal / 4
        let readiness: BaselineReadiness
        if dailyLoads.isEmpty {
            readiness = .noData
        } else if validDays < 7 || priorTotal <= 0 {
            readiness = .learning
        } else {
            readiness = .mature
        }
        let ratio = readiness == .mature && !hasUnknownEffortInRecentWindow
            ? priorAverage.flatMap { $0 > 0 ? recent / $0 : nil }
            : nil
        let band: TrainingLoadBand
        if readiness != .mature {
            band = readiness == .noData ? .unavailable : .learning
        } else if let ratio {
            switch ratio {
            case ..<0.75: band = .belowTypical
            case ..<0.90: band = .gradualReturn
            case ..<1.10: band = .nearTypical
            case ..<1.30: band = .increased
            default: band = .sharplyIncreased
            }
        } else {
            band = .unavailable
        }
        return TrainingLoadSummary(
            recentSevenDayLoad: recent,
            priorTwentyEightDayAverage: priorAverage,
            ratio: ratio,
            readiness: readiness,
            band: band,
            estimatedWorkoutCount: estimated,
            unavailableEffortCount: unavailable
        )
    }

    public func makeDailyBrief(
        days: [HealthIntelligenceDay],
        goals: GoalProfile? = nil,
        plannedWorkoutTomorrow: Bool? = nil
    ) -> HealthIntelligenceResult? {
        guard let current = days.max(by: { calendar.startOfDay(for: $0.dayStart) < calendar.startOfDay(for: $1.dayStart) }) else {
            return nil
        }
        let currentDay = calendar.startOfDay(for: current.dayStart)
        let sleep = sleepSummary(for: currentDay, samples: days.flatMap(\.sleepSamples))
        let workouts = days.flatMap(\.workouts)
        let load = trainingLoad(workouts: workouts, asOf: currentDay)

        let historical = days.filter { calendar.startOfDay(for: $0.dayStart) < currentDay }
        let domainInputs: [(HealthDomain, Double?, String)] = [
            (.nutrition, current.energyIntakeKcal, "nutrition.energyIntake.kcal"),
            (.sleep, sleep?.mainSleepMinutes, "sleep.mainSleep.minutes"),
            (.activity, current.stepCount ?? current.exerciseMinutes ?? current.activeEnergyKcal,
                current.stepCount != nil ? "activity.steps" : (current.exerciseMinutes != nil ? "activity.exerciseMinutes" : "activity.activeEnergy.kcal")),
            (.body, current.weightSamplesKilograms.last, "body.weight.kg"),
        ]
        let domains = domainInputs.map { domain, value, evidenceKey -> HealthDomainResult in
            let historicValues = historical.compactMap { day -> (date: Date, value: Double)? in
                guard let metric = metricValue(domain, from: day, allDays: days) else { return nil }
                return (calendar.startOfDay(for: day.dayStart), metric)
            }
            let baseline = baseline(for: historicValues, before: currentDay)
            let status: HealthDomainStatus
            if value == nil {
                status = .noData
            } else if baseline.readiness == .noData || baseline.readiness == .learning {
                status = .learning
            } else if let value, baseline.isSignificantChange(value) {
                status = abs(baseline.robustZScore(for: value) ?? 0) >= 3.5 ? .attention : .changed
            } else {
                status = .withinTypicalRange
            }
            return HealthDomainResult(
                domain: domain,
                status: status,
                currentValue: value,
                baseline: baseline,
                evidenceKeys: value == nil ? [] : [evidenceKey]
            )
        }
        let vitalTrends = makeVitalTrends(days: days, asOf: currentDay)
        let recovery = HealthStatePolicy.recovery(
            sleep: domains.first(where: { $0.domain == .sleep }),
            restingHeartRate: vitalTrends.first(where: { $0.metric == .restingHeartRate }),
            heartRateVariability: vitalTrends.first(where: { $0.metric == .heartRateVariability }),
            trainingLoad: load
        )
        let tomorrowGuidance = HealthStatePolicy.tomorrowGuidance(
            recovery: recovery,
            trainingLoad: load,
            plannedWorkout: plannedWorkoutTomorrow
        )
        let healthState = HealthStateV2(
            domains: domains,
            recovery: recovery,
            trainingLoad: load,
            tomorrowGuidance: tomorrowGuidance
        )
        let recommendations = RecommendationEngine().recommend(
            domains: domains,
            goal: goals,
            recovery: recovery,
            trainingLoad: load
        )
        let context = makeContextSummary(days: days, asOf: currentDay, goals: goals, recommendations: recommendations)
        let changedCount = domains.filter { $0.status == .changed || $0.status == .attention }.count
        let summary: String
        if domains.allSatisfy({ $0.status == .noData }) {
            summary = "目前没有足够的健康数据；可继续记录，空缺不会被当作零。"
        } else if recovery.status == .insufficientEvidence {
            summary = "部分数据还不够完整，我不会据此猜测你的恢复状态。"
        } else if changedCount == 0 {
            summary = "当前可用数据大致处于个人近期范围；这不是医学判断。"
        } else {
            summary = "有 \(changedCount) 个领域与近期个人基线不同；下面的提示仅供健康管理参考。"
        }
        let brief = DailyHealthBrief(
            dayStart: currentDay,
            summary: summary,
            domains: domains,
            recommendations: recommendations,
            sleep: sleep,
            vitalTrends: vitalTrends,
            trainingLoad: load,
            contextSummary: context,
            algorithmVersion: Self.algorithmVersion,
            healthState: healthState
        )
        let weightTrend = weightTrendKilograms(in: days)
        return HealthIntelligenceResult(
            dailyBrief: brief,
            weightTrendKilograms: weightTrend.difference,
            previousWeightMedianKilograms: weightTrend.previousMedian
        )
    }

    public func makeWeeklyBrief(
        days: [HealthIntelligenceDay],
        weekStart: Date,
        goals: GoalProfile? = nil
    ) -> WeeklyHealthBrief {
        let start = calendar.startOfDay(for: weekStart)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let weekDays = days.filter {
            let day = calendar.startOfDay(for: $0.dayStart)
            return day >= start && day < end
        }
        let sleeps = weekDays.compactMap { sleepSummary(for: $0.dayStart, samples: days.flatMap(\.sleepSamples))?.mainSleepMinutes }
        let intakes = weekDays.compactMap(\.energyIntakeKcal)
        let weights = weekDays.flatMap(\.weightSamplesKilograms)
        let current = weekDays.max { calendar.startOfDay(for: $0.dayStart) < calendar.startOfDay(for: $1.dayStart) }
        let history = days.filter { calendar.startOfDay(for: $0.dayStart) < start }
        let domains: [HealthDomainResult] = HealthDomain.allCases.map { domain in
            let values = history.compactMap { day -> (date: Date, value: Double)? in
                guard let value = metricValue(domain, from: day, allDays: days) else { return nil }
                return (calendar.startOfDay(for: day.dayStart), value)
            }
            let baseline = baseline(for: values, before: start)
            let value = current.flatMap { metricValue(domain, from: $0, allDays: days) }
            let status: HealthDomainStatus
            if value == nil { status = .noData }
            else if baseline.readiness == .noData || baseline.readiness == .learning { status = .learning }
            else if let value, baseline.isSignificantChange(value) {
                status = abs(baseline.robustZScore(for: value) ?? 0) >= 3.5 ? .attention : .changed
            }
            else { status = .withinTypicalRange }
            return HealthDomainResult(
                domain: domain,
                status: status,
                currentValue: value,
                baseline: baseline,
                evidenceKeys: value == nil ? [] : ["\(domain.rawValue).weekly.latest"]
            )
        }
        let workouts = days.flatMap(\.workouts)
        let load = trainingLoad(workouts: workouts, asOf: end.addingTimeInterval(-1))
        let averageSleep = Self.average(sleeps)
        let averageIntake = Self.average(intakes)
        let medianWeight = weights.isEmpty ? nil : Self.median(weights)
        let summary = weekDays.isEmpty
            ? "本周暂时没有可用记录；后续数据会进入下一次周报。"
            : "本周有 \(weekDays.count) 天包含可用健康或饮食数据；趋势只与个人基线比较。"
        return WeeklyHealthBrief(
            weekStart: start,
            weekEnd: end.addingTimeInterval(-1),
            daysWithData: weekDays.filter { Self.hasData($0) }.count,
            averageSleepMinutes: averageSleep,
            averageEnergyIntakeKcal: averageIntake,
            medianWeightKilograms: medianWeight,
            trainingLoad: load,
            domainStatuses: domains,
            summary: summary,
            algorithmVersion: Self.algorithmVersion
        )
    }

    public func weightTrendKilograms(in days: [HealthIntelligenceDay]) -> (difference: Double?, previousMedian: Double?) {
        guard let latest = days.map({ calendar.startOfDay(for: $0.dayStart) }).max(),
              let currentStart = calendar.date(byAdding: .day, value: -6, to: latest),
              let previousStart = calendar.date(byAdding: .day, value: -13, to: latest) else { return (nil, nil) }
        let currentWeights = dailyWeightMedians(days.filter {
            let day = calendar.startOfDay(for: $0.dayStart)
            return day >= currentStart && day <= latest
        })
        let previousWeights = dailyWeightMedians(days.filter {
            let day = calendar.startOfDay(for: $0.dayStart)
            return day >= previousStart && day < currentStart
        })
        guard currentWeights.count >= 4, previousWeights.count >= 4 else { return (nil, nil) }
        let currentMedian = Self.median(currentWeights.map { $0.value })
        let previousMedian = Self.median(previousWeights.map { $0.value })
        return (currentMedian - previousMedian, previousMedian)
    }

    public func makeContextSummary(
        days: [HealthIntelligenceDay],
        asOf date: Date,
        goals: GoalProfile?,
        recommendations: [HealthRecommendation]
    ) -> HealthContextSummary {
        let end = calendar.startOfDay(for: date)
        let sevenDayStart = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let twentyEightDayStart = calendar.date(byAdding: .day, value: -27, to: end) ?? end
        let windowDays = days.filter {
            let day = calendar.startOfDay(for: $0.dayStart)
            return day >= twentyEightDayStart && day <= end
        }
        let sevenDays = windowDays.filter {
            let day = calendar.startOfDay(for: $0.dayStart)
            return day >= sevenDayStart
        }
        return HealthContextSummary(
            sevenDay: contextWindow(days: sevenDays, windowDays: 7, allDays: days),
            twentyEightDay: contextWindow(days: windowDays, windowDays: 28, allDays: days),
            targetWeightKilograms: goals?.targetWeightKilograms,
            dailyDeficitGoalKcal: goals?.dailyDeficitKcal,
            dailyProteinGoalGrams: goals?.dailyProteinGrams,
            recommendationReferences: recommendations.flatMap { [$0.id, $0.evidenceKey] }
        )
    }

    private func contextWindow(
        days: [HealthIntelligenceDay],
        windowDays: Int,
        allDays: [HealthIntelligenceDay]
    ) -> HealthContextWindowSummary {
        let sleeps = days.compactMap {
            sleepSummary(for: $0.dayStart, samples: allDays.flatMap(\.sleepSamples))?.mainSleepMinutes
        }
        let weights = days.flatMap(\.weightSamplesKilograms)
        func coverage(_ predicate: (HealthIntelligenceDay) -> Bool) -> Int {
            Set(days.filter(predicate).map { calendar.startOfDay(for: $0.dayStart) }).count
        }
        return HealthContextWindowSummary(
            windowDays: windowDays,
            coverageDays: [
                "sleep": coverage { !$0.sleepSamples.isEmpty },
                "steps": coverage { $0.stepCount != nil },
                "activeEnergy": coverage { $0.activeEnergyKcal != nil },
                "energyIntake": coverage { $0.energyIntakeKcal != nil },
                "bodyMass": coverage { !$0.weightSamplesKilograms.isEmpty },
            ],
            averageSleepMinutes: Self.average(sleeps),
            averageStepCount: Self.average(days.compactMap(\.stepCount)),
            averageActiveEnergyKcal: Self.average(days.compactMap(\.activeEnergyKcal)),
            averageEnergyIntakeKcal: Self.average(days.compactMap(\.energyIntakeKcal)),
            averageDailyDeficitKcal: Self.average(days.compactMap(\.dailyDeficitKcal)),
            averageProteinGrams: Self.average(days.compactMap(\.proteinGrams)),
            medianWeightKilograms: weights.isEmpty ? nil : Self.median(weights)
        )
    }

    private func dailyWeightMedians(_ days: [HealthIntelligenceDay]) -> [(date: Date, value: Double)] {
        days.compactMap { day in
            guard !day.weightSamplesKilograms.isEmpty else { return nil }
            return (calendar.startOfDay(for: day.dayStart), Self.median(day.weightSamplesKilograms))
        }
    }

    private func makeVitalTrends(
        days: [HealthIntelligenceDay],
        asOf date: Date
    ) -> [HealthVitalTrend] {
        let today = calendar.startOfDay(for: date)
        let historical = days.filter { calendar.startOfDay(for: $0.dayStart) < today }
        return HealthVitalMetric.allCases.map { metric in
        let currentValues = days
                .filter { calendar.startOfDay(for: $0.dayStart) == today }
                .flatMap { vitalValues(metric, in: $0) }
        let currentValue = currentValues.isEmpty ? nil : Self.median(currentValues)
            let history = historical.compactMap { day -> (date: Date, value: Double)? in
                let values = vitalValues(metric, in: day)
                guard !values.isEmpty else { return nil }
                return (calendar.startOfDay(for: day.dayStart), Self.median(values))
            }
            let baseline = baseline(for: history, before: today)
            let status: HealthDomainStatus
            if currentValue == nil {
                status = .noData
            } else if baseline.readiness == .noData || baseline.readiness == .learning {
                status = .learning
            } else if let currentValue, baseline.isSignificantChange(currentValue) {
                status = abs(baseline.robustZScore(for: currentValue) ?? 0) >= 3.5 ? .attention : .changed
            } else {
                status = .withinTypicalRange
            }
            return HealthVitalTrend(
                metric: metric,
                latestMedian: currentValue,
                baseline: baseline,
                status: status,
                evidenceKey: "vitals.\(metric.rawValue).median"
            )
        }
    }

    private func vitalValues(_ metric: HealthVitalMetric, in day: HealthIntelligenceDay) -> [Double] {
        switch metric {
        case .restingHeartRate: day.restingHeartRateSamples
        case .heartRateVariability: day.heartRateVariabilitySamples
        case .respiratoryRate: day.respiratoryRateSamples
        case .wristTemperature: day.wristTemperatureSamples
        case .bodyWeight: day.weightSamplesKilograms
        }
    }

    private func metricValue(
        _ domain: HealthDomain,
        from day: HealthIntelligenceDay,
        allDays: [HealthIntelligenceDay]
    ) -> Double? {
        switch domain {
        case .nutrition: day.energyIntakeKcal
        case .sleep: sleepSummary(for: day.dayStart, samples: allDays.flatMap(\.sleepSamples))?.mainSleepMinutes
        case .activity: day.stepCount ?? day.exerciseMinutes ?? day.activeEnergyKcal
        case .body: day.weightSamplesKilograms.last
        }
    }

    private static func hasData(_ day: HealthIntelligenceDay) -> Bool {
        day.energyIntakeKcal != nil || day.stepCount != nil || day.exerciseMinutes != nil
            || !day.weightSamplesKilograms.isEmpty || !day.sleepSamples.isEmpty
    }

    private static func estimatedEffort(for intensity: String?) -> Double? {
        switch intensity?.lowercased() {
        case "light": 3
        case "moderate": 5
        case "vigorous", "high": 8
        default: nil
        }
    }

    private static func unionDuration(_ samples: [SleepSampleInterval], start: Date, end: Date) -> TimeInterval {
        let intervals = samples.compactMap { sample -> (Date, Date)? in
            let left = max(sample.startDate, start)
            let right = min(sample.endDate, end)
            return right > left ? (left, right) : nil
        }
        return merge(intervals).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }

    private static func unionDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        merge(intervals).reduce(0) { $0 + $1.1.timeIntervalSince($1.0) }
    }

    private static func subtract(
        _ interval: (Date, Date),
        coveredBy coverage: [(Date, Date)]
    ) -> [(Date, Date)] {
        var remaining = [interval]
        for covered in coverage {
            remaining = remaining.flatMap { piece -> [(Date, Date)] in
                guard covered.1 > piece.0, covered.0 < piece.1 else { return [piece] }
                var pieces: [(Date, Date)] = []
                if covered.0 > piece.0 { pieces.append((piece.0, min(covered.0, piece.1))) }
                if covered.1 < piece.1 { pieces.append((max(covered.1, piece.0), piece.1)) }
                return pieces.filter { $0.1 > $0.0 }
            }
        }
        return remaining
    }

    private static func merge(_ intervals: [(Date, Date)]) -> [(Date, Date)] {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return [] }
        var result: [(Date, Date)] = []
        for next in sorted.dropFirst() {
            if next.0 <= current.1 {
                current.1 = max(current.1, next.1)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let index = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let lower = Int(index.rounded(.down))
        let upper = Int(index.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = index - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func average(_ values: [Double]) -> Double? {
        let valid = values.filter(\.isFinite)
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }
}

public struct RecommendationEngine: Sendable {
    public init() {}

    public func recommend(
        domains: [HealthDomainResult],
        goal: GoalProfile? = nil,
        recovery: RecoveryAssessment? = nil,
        trainingLoad: TrainingLoadSummary? = nil
    ) -> [HealthRecommendation] {
        var candidates: [HealthRecommendation] = []
        for result in domains where result.status == .changed || result.status == .attention {
            guard let evidenceKey = result.evidenceKeys.first else { continue }
            let recommendation: HealthRecommendation
            switch result.domain {
            case .nutrition:
                let target = goal?.dailyDeficitKcal
                recommendation = HealthRecommendation(
                    id: "nutrition.review-balance",
                    domain: .nutrition,
                    title: "回看今天的饮食节奏",
                    detail: target.map { "可以结合自己的 \(max($0, 0)) kcal 日目标查看餐食份量。" }
                        ?? "可以回看餐食份量与记录完整度。",
                    evidenceKey: evidenceKey,
                    conflictGroup: "nutrition-balance",
                    score: result.status == .attention ? 0.9 : 0.65
                )
            case .sleep:
                recommendation = HealthRecommendation(
                    id: "sleep.consistency",
                    domain: .sleep,
                    title: "关注睡眠节奏",
                    detail: "这次睡眠时长与近期个人范围不同，可先查看记录是否完整。",
                    evidenceKey: evidenceKey,
                    conflictGroup: "sleep-routine",
                    score: result.status == .attention ? 0.88 : 0.62
                )
            case .activity:
                recommendation = HealthRecommendation(
                    id: "activity.gentle-adjustment",
                    domain: .activity,
                    title: "查看近期活动变化",
                    detail: "活动量与个人近期范围不同；可按当前状态选择轻松活动或休息。",
                    evidenceKey: evidenceKey,
                    conflictGroup: "activity-load",
                    score: result.status == .attention ? 0.86 : 0.60
                )
            case .body:
                recommendation = HealthRecommendation(
                    id: "body.review-trend",
                    domain: .body,
                    title: "以多日趋势看体重变化",
                    detail: "单次体重会波动；可结合连续记录的中位数查看趋势。",
                    evidenceKey: evidenceKey,
                    conflictGroup: "body-trend",
                    score: result.status == .attention ? 0.82 : 0.58
                )
            }
            candidates.append(recommendation)
        }

        let changedSleepEvidence = domains.first {
            $0.domain == .sleep && ($0.status == .changed || $0.status == .attention)
        }?.evidenceKeys.first
        let vitalEvidence = recovery?.evidence.first {
            $0.source == "restingHeartRate" || $0.source == "heartRateVariability"
        }?.key
        let loadEvidence = recovery?.evidence.first(where: { $0.source == "trainingLoad" })?.key
        if recovery?.status == .attention,
           (trainingLoad?.band == .increased || trainingLoad?.band == .sharplyIncreased),
           let evidenceKey = changedSleepEvidence ?? vitalEvidence ?? loadEvidence {
            candidates.append(
                HealthRecommendation(
                    id: "recovery.reduce-training-load",
                    domain: .activity,
                    title: "今天降低训练强度",
                    detail: "恢复相关数据偏离个人近期范围，可先选择轻量活动。",
                    evidenceKey: evidenceKey,
                    conflictGroup: "activity-load",
                    score: 0.97
                )
            )
        }

        var usedGroups = Set<String>()
        var selected: [HealthRecommendation] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard usedGroups.insert(candidate.conflictGroup).inserted else { continue }
            selected.append(candidate)
            if selected.count == 2 { break }
        }
        return selected
    }
}
