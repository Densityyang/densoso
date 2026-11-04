import DensosoDomain
import Foundation

enum DailyHealthSampleSummaryBuilder {
    static func build(
        samples: [HealthSampleSnapshot],
        dayStart: Date,
        sleepSamples: [HealthSampleSnapshot]? = nil,
        workouts: [WorkoutRecord]
    ) -> DailyHealthSampleSummary {
        let validWorkouts = workouts.filter { $0.durationMinutes > 0 }
        let validEffortSamples = HealthSampleSnapshot.deduplicated(samples)
            .filter { $0.metric == .workoutEffort && $0.value.map { (1...10).contains($0) } == true }
        let candidates = validEffortSamples.flatMap { sample in
            validWorkouts.compactMap { workout -> (sample: HealthSampleSnapshot, workout: WorkoutRecord, overlap: TimeInterval)? in
                let duration = overlap(
                    sample,
                    start: workout.date,
                    end: workout.date.addingTimeInterval(Double(workout.durationMinutes) * 60)
                )
                return duration > 0 ? (sample, workout, duration) : nil
            }
        }.sorted { lhs, rhs in
            if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
            if lhs.sample.startDate != rhs.sample.startDate { return lhs.sample.startDate < rhs.sample.startDate }
            if lhs.sample.id != rhs.sample.id { return lhs.sample.id.uuidString < rhs.sample.id.uuidString }
            if lhs.workout.date != rhs.workout.date { return lhs.workout.date < rhs.workout.date }
            return lhs.workout.id.uuidString < rhs.workout.id.uuidString
        }
        var assignedSampleIDs = Set<UUID>()
        var assignedWorkoutIDs = Set<UUID>()
        var assignedSamplesByWorkout: [UUID: HealthSampleSnapshot] = [:]

        // Effort samples and workouts are both one-to-one here. Greedily take
        // the strongest temporal matches first; deterministic ties keep the
        // result stable when HealthKit returns records in a different order.
        for candidate in candidates {
            guard !assignedSampleIDs.contains(candidate.sample.id),
                  !assignedWorkoutIDs.contains(candidate.workout.id) else { continue }
            assignedSampleIDs.insert(candidate.sample.id)
            assignedWorkoutIDs.insert(candidate.workout.id)
            assignedSamplesByWorkout[candidate.workout.id] = candidate.sample
        }

        let efforts = validWorkouts.compactMap { workout -> WorkoutEffortDailyAggregate? in
            guard let score = assignedSamplesByWorkout[workout.id]?.value else { return nil }
            return WorkoutEffortDailyAggregate(workoutRecordID: workout.id, score: score)
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
