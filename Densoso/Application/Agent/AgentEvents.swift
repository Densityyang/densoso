import DensosoDomain
import Foundation

enum AgentEvent: Equatable, Sendable {
    case accepted(requestID: UUID)
    case providerRoundStarted(provider: ProviderID, round: Int)
    case assistantDelta(String)
    case toolCallStarted(name: String, index: Int)
    case pendingAction(PendingAction)
    case usage(ProviderUsage)
    case budgetWarning(provider: ProviderID)
    case completed(AgentResponse)
    case cancelled(requestID: UUID)
    case failed(String)
}

struct AgentResponse: Equatable, Sendable {
    let text: String
    let toolCallsCount: Int
    let providerRoundsCount: Int
}
