import XCTest
import SwiftData
@testable import Densoso

final class AgentBudgetTests: XCTestCase {
    func testFiveRoundsAndEightToolsAreHardLimits() throws {
        let deadline = Date(timeIntervalSince1970: 2_000)
        var tracker = AgentBudgetTracker(
            budget: AgentBudget(
                maximumProviderRounds: 5,
                maximumToolCalls: 8,
                deadline: deadline
            )
        )
        for _ in 0..<5 { try tracker.consumeProviderRound(now: deadline.addingTimeInterval(-1)) }
        XCTAssertThrowsError(try tracker.consumeProviderRound(now: deadline.addingTimeInterval(-1)))
        for _ in 0..<8 { try tracker.consumeToolCall(now: deadline.addingTimeInterval(-1)) }
        XCTAssertThrowsError(try tracker.consumeToolCall(now: deadline.addingTimeInterval(-1)))
        XCTAssertEqual(tracker.providerRounds, 5)
        XCTAssertEqual(tracker.toolCalls, 8)
    }

    func testDeadlineIsSharedAcrossRoundsAndTools() {
        var tracker = AgentBudgetTracker(
            budget: AgentBudget(deadline: Date(timeIntervalSince1970: 1_000))
        )
        XCTAssertThrowsError(
            try tracker.consumeProviderRound(now: Date(timeIntervalSince1970: 1_000))
        ) { error in
            XCTAssertEqual(error as? ProviderError, .timeout)
        }
    }

    @MainActor
    func testUnavailableCostReservationCannotExceedPersistedProviderRoundBudget() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let requestID = UUID()
        let conversationID = UUID()
        let now = Date()
        _ = try await repository.beginAgentRequest(
            requestID: requestID,
            conversationID: conversationID,
            initialBudget: AgentBudget(
                maximumProviderRounds: 1,
                maximumToolCalls: 1,
                maximumCostMicros: 100,
                deadline: now.addingTimeInterval(60)
            ),
            startedAt: now,
            containsTransientImage: false
        )

        _ = try await repository.reserveAgentRequestCost(
            requestID: requestID,
            conversationID: conversationID,
            provider: .deepSeek,
            model: "deepseek-flash",
            currency: "unavailable",
            pricingVersion: "unknown",
            providerRound: 1,
            estimatedCostMicros: nil
        )

        do {
            _ = try await repository.reserveAgentRequestCost(
                requestID: requestID,
                conversationID: conversationID,
                provider: .deepSeek,
                model: "deepseek-flash",
                currency: "unavailable",
                pricingVersion: "unknown",
                providerRound: 2,
                estimatedCostMicros: nil
            )
            XCTFail("An unavailable price must not bypass the persisted provider-round limit")
        } catch {
            XCTAssertEqual(error as? AgentRequestPersistenceError, .costBudgetExceeded)
        }
    }

    @MainActor
    func testAgentUsageRejectsCachedTokensAboveInputBeforePersistence() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let requestID = UUID()
        let conversationID = UUID()
        let now = Date()
        _ = try await repository.beginAgentRequest(
            requestID: requestID,
            conversationID: conversationID,
            initialBudget: AgentBudget(deadline: now.addingTimeInterval(60)),
            startedAt: now,
            containsTransientImage: false
        )
        let expectedError = AgentRequestPersistenceError.invalidState(
            "cached input tokens exceed input tokens"
        )

        do {
            try await repository.addAgentRequestUsage(
                requestID: requestID,
                conversationID: conversationID,
                usage: AgentTokenUsage(inputTokens: 10, cachedInputTokens: 11, outputTokens: 1)
            )
            XCTFail("Invalid cached usage must be rejected before updating the request ledger")
        } catch {
            XCTAssertEqual(error as? AgentRequestPersistenceError, expectedError)
        }

        do {
            try await repository.updateAgentRequestConsumption(
                requestID: requestID,
                conversationID: conversationID,
                consumption: AgentBudgetConsumption(inputTokens: 10, cachedInputTokens: 11)
            )
            XCTFail("Invalid cached consumption must be rejected before updating the request ledger")
        } catch {
            XCTAssertEqual(error as? AgentRequestPersistenceError, expectedError)
        }

        let storedRequest = try await repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(storedRequest?.consumption.inputTokens, 0)
        XCTAssertEqual(storedRequest?.consumption.cachedInputTokens, 0)
    }
}
