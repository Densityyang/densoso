import DensosoDomain
import Foundation

struct AgentTurnResult: Equatable, Sendable {
    let text: String
    let intents: [AgentIntent]
    let stagedActionIDs: [UUID]
}

enum AgentTurnContract {
    static func local(_ result: LocalIntelligenceResult) -> AgentTurnResult {
        guard let suggestion = result.suggestion else {
            return AgentTurnResult(
                text: result.reply,
                intents: [.answer(result.reply)],
                stagedActionIDs: []
            )
        }
        return AgentTurnResult(
            text: result.reply,
            intents: [.captureProposal(suggestion)],
            stagedActionIDs: []
        )
    }

    static func cloud(reply: String, stagedActions: [PendingAction]) -> AgentTurnResult {
        let intents = stagedActions.map { intent(for: $0.payload) }
        return AgentTurnResult(
            text: reply,
            // A no-action response stays generic until the session returns a
            // structured read intent; wording alone is not enough evidence.
            intents: intents.isEmpty ? [.answer(reply)] : intents,
            stagedActionIDs: stagedActions.map(\.id)
        )
    }

    private static func intent(for payload: ActionPayload) -> AgentIntent {
        switch payload {
        case .meal(let draft): .recordMeal(draft)
        case .weight(let draft): .recordWeight(draft)
        case .workoutPlan(let draft): .createWorkoutPlan(draft)
        case .trainingPlan(let draft): .createTrainingPlan(draft)
        case .dailyCheckIn(let checkIn): .dailyCheckIn(checkIn)
        case .userPreference(let preference): .recordUserPreference(preference)
        }
    }
}
