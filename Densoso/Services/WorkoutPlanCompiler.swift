import Foundation
import HealthKit
import Observation
import WorkoutKit

enum WorkoutPlanCompileError: LocalizedError, Equatable {
    case emptyName
    case invalidTimeGoal
    case invalidStrengthSet
    case unsupportedActivity
    case unsupportedGoal
    case scheduleDateRequired
    case scheduleAuthorizationDenied
    case schedulingUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName: "请为训练计划填写名称。"
        case .invalidTimeGoal: "训练时长需在 1 到 720 分钟之间。"
        case .invalidStrengthSet: "力量训练的动作名称、组数、次数或重量无效。"
        case .unsupportedActivity: "此设备的 Workout App 不支持该训练类型。"
        case .unsupportedGoal: "该训练类型不支持所选目标。"
        case .scheduleDateRequired: "请先选择训练开始时间，再同步到 Apple Watch。"
        case .scheduleAuthorizationDenied: "未获得将训练计划同步到 Apple Watch 的授权。"
        case .schedulingUnavailable: "此设备当前不支持训练计划同步。"
        }
    }
}

/// Validates and compiles a user-confirmed app draft into Apple's WorkoutKit plan.
/// Strength sets stay in app-domain data; WorkoutKit only receives the supported
/// workout activity and goal.
struct WorkoutPlanCompiler {
    func validate(_ draft: WorkoutPlanDraft) throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkoutPlanCompileError.emptyName
        }

        if case .timeMinutes(let minutes) = draft.goal,
           !(1...720).contains(minutes) {
            throw WorkoutPlanCompileError.invalidTimeGoal
        }

        for set in draft.strengthSets {
            let validLoad = set.loadKilograms.map { (0...1_000).contains($0) } ?? true
            guard !set.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...100).contains(set.setCount),
                  (1...1_000).contains(set.repetitions),
                  validLoad else {
                throw WorkoutPlanCompileError.invalidStrengthSet
            }
        }
    }

    func compile(_ draft: WorkoutPlanDraft) throws -> WorkoutPlan {
        try validate(draft)

        let activity = healthKitActivity(for: draft.activity)
        let location = healthKitLocation(for: draft.location)
        let goal = workoutGoal(for: draft.goal)

        guard SingleGoalWorkout.supportsActivity(activity) else {
            throw WorkoutPlanCompileError.unsupportedActivity
        }
        guard SingleGoalWorkout.supportsGoal(goal, activity: activity, location: location) else {
            throw WorkoutPlanCompileError.unsupportedGoal
        }

        let workout = SingleGoalWorkout(activity: activity, location: location, goal: goal)
        return WorkoutPlan(.goal(workout), id: draft.id)
    }

    private func healthKitActivity(for activity: WorkoutPlanDraft.Activity) -> HKWorkoutActivityType {
        switch activity {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .strength: .traditionalStrengthTraining
        case .hiit: .highIntensityIntervalTraining
        }
    }

    private func healthKitLocation(for location: WorkoutPlanDraft.Location) -> HKWorkoutSessionLocationType {
        location == .indoor ? .indoor : .outdoor
    }

    private func workoutGoal(for goal: WorkoutPlanDraft.Goal) -> WorkoutGoal {
        switch goal {
        case .open: .open
        case .timeMinutes(let minutes): .time(Double(minutes), .minutes)
        }
    }
}

@MainActor
@Observable
final class WorkoutPlanSchedulingService {
    private let compiler = WorkoutPlanCompiler()

    func previewOrSchedule(_ draft: WorkoutPlanDraft) async throws {
        let plan = try compiler.compile(draft)

        guard let scheduledAt = draft.scheduledAt else { throw WorkoutPlanCompileError.scheduleDateRequired }

        guard WorkoutScheduler.isSupported else {
            throw WorkoutPlanCompileError.schedulingUnavailable
        }
        let scheduler = WorkoutScheduler.shared
        guard await scheduler.requestAuthorization() == .authorized else {
            throw WorkoutPlanCompileError.scheduleAuthorizationDenied
        }
        await scheduler.schedule(plan, at: Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: scheduledAt
        ))
    }
}
