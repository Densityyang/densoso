import Foundation

public struct HealthMetricSampleAggregate: Codable, Equatable, Sendable {
    public let metric: HealthMetricID
    public let sampleCount: Int
    public let averageValue: Double?
    public let minimumValue: Double?
    public let maximumValue: Double?
    public let latestValue: Double?
    public let latestSampleAt: Date?
    public let latestSampleID: UUID?

    public init(metric: HealthMetricID, samples: [HealthSampleSnapshot]) {
        let values = HealthSampleSnapshot.deduplicated(samples).compactMap { sample -> (date: Date, id: UUID, value: Double)? in
            guard sample.metric == metric,
                  let value = sample.value,
                  value.isFinite,
                  sample.endDate.timeIntervalSince1970.isFinite else { return nil }
            return (sample.endDate, sample.id, value)
        }
        self.metric = metric
        sampleCount = values.count
        averageValue = values.isEmpty ? nil : values.reduce(0) { $0 + $1.value } / Double(values.count)
        minimumValue = values.map(\.value).min()
        maximumValue = values.map(\.value).max()
        let latest = values.max {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        latestValue = latest?.value
        latestSampleAt = latest?.date
        latestSampleID = latest?.id
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
                selectedSourceBundleIdentifier: nil
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
