import DensosoDomain
import Foundation

enum DailyHealthSampleSummaryBuilder {
    static func build(
        samples: [HealthSampleSnapshot],
        dayStart: Date,
        sleepSamples: [HealthSampleSnapshot]? = nil,
        workouts: [WorkoutRecord]
    ) -> DailyHealthSampleSummary {
        let efforts = workouts.compactMap { workout -> WorkoutEffortDailyAggregate? in
            let workoutStart = workout.date
            let workoutEnd = workoutStart.addingTimeInterval(Double(max(workout.durationMinutes, 0)) * 60)
            let bestEffort = samples
                .filter { sample in
                    sample.metric == .workoutEffort && overlap(sample, start: workoutStart, end: workoutEnd) > 0
                }
                .max {
                    overlap($0, start: workoutStart, end: workoutEnd)
                        < overlap($1, start: workoutStart, end: workoutEnd)
                }?.value
            guard let bestEffort else { return nil }
            return WorkoutEffortDailyAggregate(workoutRecordID: workout.id, score: bestEffort)
        }
        return DailyHealthSampleSummary(
            samples: samples,
            dayStart: dayStart,
            sleepSamples: sleepSamples,
            workoutEffort: efforts
        )
    }

    private static func overlap(_ sample: HealthSampleSnapshot, start: Date, end: Date) -> TimeInterval {
        max(min(sample.endDate, end).timeIntervalSince(max(sample.startDate, start)), 0)
    }
}
