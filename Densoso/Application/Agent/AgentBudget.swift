import Foundation

struct AgentBudget: Equatable, Sendable {
    let maximumProviderRounds: Int
    let maximumToolCalls: Int
    let deadline: Date

    init(
        maximumProviderRounds: Int = 5,
        maximumToolCalls: Int = 8,
        deadline: Date = Date().addingTimeInterval(45)
    ) {
        self.maximumProviderRounds = maximumProviderRounds
        self.maximumToolCalls = maximumToolCalls
        self.deadline = deadline
    }
}

struct AgentBudgetTracker: Sendable {
    let budget: AgentBudget
    private(set) var providerRounds = 0
    private(set) var toolCalls = 0

    mutating func consumeProviderRound(now: Date = Date()) throws {
        try requireTime(now: now)
        guard providerRounds < budget.maximumProviderRounds else {
            throw ProviderError.budgetExceeded
        }
        providerRounds += 1
    }

    mutating func consumeToolCall(now: Date = Date()) throws {
        try requireTime(now: now)
        guard toolCalls < budget.maximumToolCalls else {
            throw ProviderError.budgetExceeded
        }
        toolCalls += 1
    }

    func requireTime(now: Date = Date()) throws {
        guard now < budget.deadline else { throw ProviderError.timeout }
    }
}
