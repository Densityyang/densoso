import Foundation
import WorkoutKit
import DensosoDomain

struct CompiledTrainingSession: Identifiable {
    let draft: TrainingSessionDraft
    let workoutPlan: WorkoutPlan?

    var id: UUID { draft.id }
}

struct CompiledTrainingPlan {
    let id: UUID
    let name: String
    let createdAt: Date
    let sessions: [CompiledTrainingSession]

    var workoutSessions: [CompiledTrainingSession] {
        sessions.filter { session in
            if case .some = session.workoutPlan { return true }
            return false
        }
    }
}

enum TrainingPlanCompileError: Error, LocalizedError, Equatable {
    case invalidDraft(TrainingPlanDraftValidationError)
    case sessionInPast

    var errorDescription: String? {
        switch self {
        case .sessionInPast: "计划中有已经开始或过期的训练日，请重新生成计划。"
        case .invalidDraft(.invalidName): "训练计划需要一个不超过 100 个字符的名称。"
        case .invalidDraft(.invalidDate): "训练计划包含无效日期。"
        case .invalidDraft(.invalidSessionCount): "训练计划需要包含 1 到 14 天。"
        case .invalidDraft(.duplicateSessionIdentity): "训练计划包含重复的训练记录。"
        case .invalidDraft(.invalidReason): "每天都需要填写不超过 240 个字符的安排说明。"
        case .invalidDraft(.invalidRestSession): "休息日不能同时包含运动、目标、地点或强度。"
        case .invalidDraft(.invalidWorkoutSession): "训练日需要受支持的活动类型、目标、地点和强度。"
        case .invalidDraft(.invalidGoal): "训练目标超出可安排范围。"
        }
    }
}

/// Converts every workout day in a confirmed multi-day plan to an independent
/// WorkoutKit plan. Rest days remain part of the app-owned plan and are not
/// sent to WorkoutKit.
struct TrainingPlanCompiler {
    private let workoutPlanCompiler = WorkoutPlanCompiler()

    func compile(_ draft: TrainingPlanDraft) throws -> CompiledTrainingPlan {
        if let validationError = draft.validationError {
            throw TrainingPlanCompileError.invalidDraft(validationError)
        }
        guard draft.sessions
            .filter({ !$0.isRestDay })
            .allSatisfy({ $0.date > Date() }) else {
            throw TrainingPlanCompileError.sessionInPast
        }

        let sessions = try draft.sessions
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { session -> CompiledTrainingSession in
                guard let activity = session.activity,
                      let goal = session.goal,
                      let location = session.location else {
                    // Rest days stay in the draft, with no WorkoutKit plan.
                    return CompiledTrainingSession(draft: session, workoutPlan: nil)
                }
                let singleSessionDraft = WorkoutPlanDraft(
                    id: session.id,
                    name: "\(draft.name) · \(activity.displayName)",
                    activity: activity,
                    location: location,
                    goal: goal,
                    scheduledAt: session.date
                )
                return CompiledTrainingSession(
                    draft: session,
                    workoutPlan: try workoutPlanCompiler.compile(singleSessionDraft)
                )
            }

        return CompiledTrainingPlan(
            id: draft.id,
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: draft.createdAt,
            sessions: sessions
        )
    }

}
