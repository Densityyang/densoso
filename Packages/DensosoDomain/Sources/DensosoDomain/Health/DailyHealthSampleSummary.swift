import Foundation

private struct ValidMetricSample {
    let startDate: Date
    let endDate: Date
    let id: UUID
    let value: Double
    let sourceIdentifier: String
}

public struct HealthMetricSampleAggregate: Codable, Equatable, Sendable {
    public let metric: HealthMetricID
    /// Effective independent measurement windows after cross-source collapse.
    public let sampleCount: Int
    /// UUID-unique HealthKit samples before time-window/source aggregation.
    public let rawSampleCount: Int
    public let averageValue: Double?
    /// Daily representative chosen with the metric's sampling behavior in mind.
    /// `averageValue` remains the raw sample-weighted statistic for compatibility.
    public let representativeValue: Double?
    public let minimumValue: Double?
    public let maximumValue: Double?
    public let latestValue: Double?
    public let latestSampleAt: Date?
    public let latestSampleID: UUID?

    public init(metric: HealthMetricID, samples: [HealthSampleSnapshot]) {
        let values = HealthSampleSnapshot.deduplicated(samples).compactMap { sample -> ValidMetricSample? in
            guard sample.metric == metric,
                  let value = sample.value,
                  Self.isValidMeasurement(value, for: metric),
                  value.isFinite,
                  sample.startDate.timeIntervalSince1970.isFinite,
                  sample.endDate.timeIntervalSince1970.isFinite else { return nil }
            let sourceIdentifier = HealthSourceIdentity.key(
                bundleIdentifier: sample.sourceBundleIdentifier,
                deviceModel: sample.deviceModel
            )
            return ValidMetricSample(
                startDate: sample.startDate,
                endDate: sample.endDate,
                id: sample.id,
                value: value,
                sourceIdentifier: sourceIdentifier
            )
        }
        self.metric = metric
        rawSampleCount = values.count
        averageValue = values.isEmpty ? nil : values.reduce(0) { $0 + $1.value } / Double(values.count)
        minimumValue = values.map(\.value).min()
        maximumValue = values.map(\.value).max()
        let latest = values.max {
            $0.endDate == $1.endDate
                ? $0.id.uuidString < $1.id.uuidString
                : $0.endDate < $1.endDate
        }
        latestValue = latest?.value
        latestSampleAt = latest?.endDate
        latestSampleID = latest?.id
        let bucketDuration = Self.aggregationBucketDuration(for: metric)
        let independentWindows = bucketDuration.map {
            Self.crossSourceWindowValues(values, bucketDuration: $0, useMedianWithinSource: metric != .heartRate)
        }
        sampleCount = independentWindows?.count ?? values.count
        let independentWindowValues = independentWindows ?? []
        switch metric {
        case .heartRate:
            // Dense exercise intervals no longer outweigh sparsely sampled
            // windows. Each represented 15-minute interval contributes once.
            representativeValue = independentWindowValues.isEmpty
                ? nil
                : independentWindowValues.reduce(0, +) / Double(independentWindowValues.count)
        case .restingHeartRate, .bodyMass:
            // HealthKit's newest resting-rate or body-mass observation is the
            // current daily signal; averaging revisions and repeat readings
            // makes the result depend on how often the device sampled.
            representativeValue = latest?.value
        case .heartRateVariabilitySDNN, .respiratoryRate, .wristTemperature:
            // These measures are intermittent and can have outlying readings.
            // Take the median of hourly, source-collapsed values.
            representativeValue = Self.median(independentWindowValues)
        default:
            representativeValue = averageValue
        }
    }

    private static func aggregationBucketDuration(for metric: HealthMetricID) -> TimeInterval? {
        switch metric {
        case .heartRate: 15 * 60
        case .heartRateVariabilitySDNN, .respiratoryRate, .wristTemperature: 60 * 60
        default: nil
        }
    }

    private static func isValidMeasurement(_ value: Double, for metric: HealthMetricID) -> Bool {
        guard value.isFinite else { return false }
        switch metric {
        case .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate,
             .bodyMass, .height:
            return value > 0
        case .stepCount, .activeEnergy, .restingEnergy, .exerciseMinutes,
             .dietaryEnergy, .dietaryProtein, .dietaryFat, .dietaryCarbohydrates:
            return value >= 0
        case .bodyFatPercentage:
            return (0...100).contains(value)
        case .workoutEffort:
            return (1...10).contains(value)
        case .workout, .sleepAnalysis, .wristTemperature:
            return true
        }
    }

    private static func crossSourceWindowValues(
        _ samples: [ValidMetricSample],
        bucketDuration: TimeInterval,
        useMedianWithinSource: Bool
    ) -> [Double] {
        let windows = Dictionary(grouping: samples) { sample in
            floor(sample.startDate.timeIntervalSince1970 / bucketDuration)
        }
        return windows.keys.sorted().compactMap { window in
            guard let windowSamples = windows[window], !windowSamples.isEmpty else { return nil }
            let sourceValues = Dictionary(grouping: windowSamples, by: \.sourceIdentifier)
                .values
                .compactMap { sourceSamples -> Double? in
                    let sourceReadings = sourceSamples.map(\.value)
                    if useMedianWithinSource { return Self.median(sourceReadings) }
                    return sourceReadings.reduce(0, +) / Double(sourceReadings.count)
                }
            return Self.median(sourceValues)
        }
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private enum CodingKeys: String, CodingKey {
        case metric
        case sampleCount
        case rawSampleCount
        case averageValue
        case representativeValue
        case minimumValue
        case maximumValue
        case latestValue
        case latestSampleAt
        case latestSampleID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metric = try container.decode(HealthMetricID.self, forKey: .metric)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        rawSampleCount = try container.decodeIfPresent(Int.self, forKey: .rawSampleCount) ?? sampleCount
        averageValue = try container.decodeIfPresent(Double.self, forKey: .averageValue)
        representativeValue = try container.decodeIfPresent(Double.self, forKey: .representativeValue) ?? averageValue
        minimumValue = try container.decodeIfPresent(Double.self, forKey: .minimumValue)
        maximumValue = try container.decodeIfPresent(Double.self, forKey: .maximumValue)
        latestValue = try container.decodeIfPresent(Double.self, forKey: .latestValue)
        latestSampleAt = try container.decodeIfPresent(Date.self, forKey: .latestSampleAt)
        latestSampleID = try container.decodeIfPresent(UUID.self, forKey: .latestSampleID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metric, forKey: .metric)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(rawSampleCount, forKey: .rawSampleCount)
        try container.encodeIfPresent(averageValue, forKey: .averageValue)
        try container.encodeIfPresent(representativeValue, forKey: .representativeValue)
        try container.encodeIfPresent(minimumValue, forKey: .minimumValue)
        try container.encodeIfPresent(maximumValue, forKey: .maximumValue)
        try container.encodeIfPresent(latestValue, forKey: .latestValue)
        try container.encodeIfPresent(latestSampleAt, forKey: .latestSampleAt)
        try container.encodeIfPresent(latestSampleID, forKey: .latestSampleID)
    }
}

public struct WorkoutEffortDailyAggregate: Codable, Equatable, Sendable {
    public let workoutRecordID: UUID
    public let score: Double

    public init(workoutRecordID: UUID, score: Double) {
        self.workoutRecordID = workoutRecordID
        self.score = score
    }
}

/// A compact daily summary. Raw HealthKit objects and their metadata are never encoded here.
public struct DailyHealthSampleSummary: Codable, Equatable, Sendable {
    public let metrics: [HealthMetricSampleAggregate]
    public let sleep: SleepSummary?
    public let workoutEffort: [WorkoutEffortDailyAggregate]

    public init(
        samples: [HealthSampleSnapshot],
        dayStart: Date,
        sleepSamples: [HealthSampleSnapshot]? = nil,
        workoutEffort: [WorkoutEffortDailyAggregate] = []
    ) {
        let uniqueSamples = HealthSampleSnapshot.deduplicated(samples)
        let samplesByMetric = Dictionary(grouping: uniqueSamples, by: \.metric)
        metrics = samplesByMetric.keys.sorted { $0.rawValue < $1.rawValue }.map { metric in
            HealthMetricSampleAggregate(metric: metric, samples: samplesByMetric[metric] ?? [])
        }
        let uniqueSleepSamples = HealthSampleSnapshot.deduplicated(sleepSamples ?? uniqueSamples)
        let sleepIntervals = uniqueSleepSamples.compactMap { sample -> SleepSampleInterval? in
            guard sample.metric == .sleepAnalysis,
                  let categoryValue = sample.categoryValue,
                  let stage = Self.sleepStage(from: categoryValue) else { return nil }
            return SleepSampleInterval(
                startDate: sample.startDate,
                endDate: sample.endDate,
                stage: stage,
                sourceBundleIdentifier: sample.sourceBundleIdentifier,
                deviceModel: sample.deviceModel
            )
        }
        let computedSleep = HealthIntelligenceEngine().sleepSummary(for: dayStart, samples: sleepIntervals)
        sleep = computedSleep.map {
            SleepSummary(
                wakeDate: $0.wakeDate,
                totalAsleepMinutes: $0.totalAsleepMinutes,
                mainSleepMinutes: $0.mainSleepMinutes,
                napMinutes: $0.napMinutes,
                stageCoverage: $0.stageCoverage,
                stages: $0.stages,
                selectedSourceBundleIdentifier: $0.selectedSourceBundleIdentifier,
                selectedSourceIdentifier: $0.selectedSourceIdentifier,
                supplementalSourceIdentifiers: $0.supplementalSourceIdentifiers,
                sourceCoverage: $0.sourceCoverage,
                hasConflictingSourceStages: $0.hasConflictingSourceStages,
                algorithmVersion: $0.algorithmVersion
            )
        }
        self.workoutEffort = workoutEffort.sorted {
            $0.workoutRecordID.uuidString < $1.workoutRecordID.uuidString
        }
    }

    public init(
        metrics: [HealthMetricSampleAggregate],
        sleep: SleepSummary?,
        workoutEffort: [WorkoutEffortDailyAggregate]
    ) {
        self.metrics = metrics.sorted { $0.metric.rawValue < $1.metric.rawValue }
        self.sleep = sleep
        self.workoutEffort = workoutEffort.sorted {
            $0.workoutRecordID.uuidString < $1.workoutRecordID.uuidString
        }
    }

    public func aggregate(for metric: HealthMetricID) -> HealthMetricSampleAggregate? {
        metrics.first { $0.metric == metric }
    }

    public func effortScore(for workoutRecordID: UUID) -> Double? {
        workoutEffort.first { $0.workoutRecordID == workoutRecordID }?.score
    }

    private static func sleepStage(from rawValue: String) -> SleepStage? {
        switch rawValue {
        case "inBed", "0": .inBed
        case "awake", "2": .awake
        case "asleepCore", "3": .asleepCore
        case "asleepDeep", "4": .asleepDeep
        case "asleepREM", "5": .asleepREM
        case "asleepUnspecified", "asleep", "1", "6": .asleepUnspecified
        default: nil
        }
    }
}
