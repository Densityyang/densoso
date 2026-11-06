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

enum TrainingPlanCompileError: Equatable, SharedErrorDescribing {
    case invalidDraft(TrainingPlanDraftValidationError)
    case sessionInPast

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .invalidDraft:
            SharedErrorDescriptor(
                code: .toolArgumentsInvalid,
                userMessage: "训练计划暂时无法安排，请检查计划内容后重试。",
                subsystem: .workoutKit,
                reason: .invalidWorkoutPlan
            )
        case .sessionInPast:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "计划中有已经开始或过期的训练日，请重新生成计划。",
                subsystem: .workoutKit,
                reason: .workoutPlanConflict
            )
        }
    }

    var errorDescription: String? { sharedErrorDescriptor.userMessage }
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
