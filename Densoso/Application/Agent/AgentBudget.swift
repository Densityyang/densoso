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
        self.maximumProviderRounds = max(maximumProviderRounds, 0)
        self.maximumToolCalls = max(maximumToolCalls, 0)
        self.deadline = deadline
    }

}

struct AgentBudgetTracker: Sendable {
    let budget: AgentBudget
    private(set) var consumption: AgentBudgetConsumption

    var providerRounds: Int { consumption.providerRoundsUsed }
    var toolCalls: Int { consumption.toolCallsUsed }
    var remainingProviderRounds: Int { max(budget.maximumProviderRounds - providerRounds, 0) }
    var remainingToolCalls: Int { max(budget.maximumToolCalls - toolCalls, 0) }

    init(budget: AgentBudget, consumption: AgentBudgetConsumption = .zero) {
        self.budget = budget
        self.consumption = consumption
    }

    mutating func consumeProviderRound(now: Date = Date()) throws {
        try requireTime(now: now)
        guard remainingProviderRounds > 0 else {
            throw ProviderError.budgetExceeded
        }
        consumption = consumption.addingProviderRound()
    }

    mutating func consumeToolCall(now: Date = Date()) throws {
        try requireTime(now: now)
        guard remainingToolCalls > 0 else {
            throw ProviderError.budgetExceeded
        }
        consumption = consumption.addingToolCall()
    }

    mutating func record(_ usage: AgentTokenUsage) {
        consumption = consumption.adding(usage)
    }

    func requireTime(now: Date = Date()) throws {
        guard now < budget.deadline else { throw ProviderError.timeout }
    }
}
