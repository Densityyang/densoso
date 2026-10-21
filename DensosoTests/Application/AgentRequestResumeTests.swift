import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class AgentRequestResumeTests: XCTestCase {
    func testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
        let deadline = Date().addingTimeInterval(60)
        let usageOne = ProviderUsage(
            provider: .deepSeek,
            model: "resume-test",
            capability: .text,
            inputTokens: 40,
            outputTokens: 12,
            audioSeconds: 0,
            attempt: 1,
            cachedInputTokens: 10,
            reasoningTokens: 3
        )
        let interruptedProvider = ScriptedTextProvider(scripts: [
            [
                .toolCall(ToolCall(id: "tool-1", name: "unknown_read", arguments: .object([:]))),
                .usage(usageOne),
                .completed(.toolUse),
            ],
            [],
        ])
        let firstRepository = SwiftDataAgentRepository(modelContainer: container)
        let firstSession = makeSession(
            container: container,
            repository: firstRepository,
            provider: interruptedProvider,
            conversationID: conversationID,
            budget: AgentBudget(maximumProviderRounds: 3, maximumToolCalls: 2, deadline: deadline)
        )

        do {
            _ = try await firstSession.send(userText: "恢复预算请求", requestID: requestID)
            XCTFail("Expected the intentionally empty second provider round to interrupt the request")
        } catch {
            XCTAssertEqual(error as? AgentError, .emptyResponse)
        }

        let createdConversationToolSchemaVersion = try await firstRepository.toolSchemaVersion(
            conversationID: conversationID
        )
        XCTAssertEqual(createdConversationToolSchemaVersion, ToolSchemaVersion.current)

        let beforeResumeValue = try await firstRepository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let beforeResume = try XCTUnwrap(beforeResumeValue)
        XCTAssertEqual(beforeResume.state, .interrupted)
        XCTAssertFalse(beforeResume.containsTransientImage)
        XCTAssertEqual(beforeResume.budget.deadline, deadline)
        XCTAssertEqual(beforeResume.consumption.providerRoundsUsed, 2)
        XCTAssertEqual(beforeResume.consumption.toolCallsUsed, 1)
        XCTAssertEqual(beforeResume.consumption.inputTokens, 40)
        XCTAssertEqual(beforeResume.consumption.cachedInputTokens, 10)
        XCTAssertEqual(beforeResume.consumption.outputTokens, 12)
        XCTAssertEqual(beforeResume.consumption.reasoningTokens, 3)

        // Recreate the repository/session as after process restoration. A larger
        // factory budget must not replace the request's original limits/deadline.
        let resumedRepository = SwiftDataAgentRepository(modelContainer: container)
        let resumedProvider = ScriptedTextProvider(scripts: [[
            .toolCall(ToolCall(id: "tool-2", name: "unknown_read", arguments: .object([:]))),
            .usage(ProviderUsage(
                provider: .deepSeek,
                model: "resume-test",
                capability: .text,
                inputTokens: 20,
                outputTokens: 6,
                audioSeconds: 0,
                attempt: 1,
                cachedInputTokens: 5,
                reasoningTokens: 2
            )),
            .completed(.toolUse),
        ]])
        let resumedSession = makeSession(
            container: container,
            repository: resumedRepository,
            provider: resumedProvider,
            conversationID: conversationID,
            budget: AgentBudget(maximumProviderRounds: 20, maximumToolCalls: 20, deadline: .distantFuture)
        )
        try await resumedSession.restore()

        do {
            _ = try await resumedSession.send(userText: "ignored replay text", requestID: requestID)
            XCTFail("The resumed request must stop after its one remaining provider round")
        } catch {
            XCTAssertEqual(error as? ProviderError, .budgetExceeded)
        }

        let afterResumeValue = try await resumedRepository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let afterResume = try XCTUnwrap(afterResumeValue)
        XCTAssertEqual(afterResume.startedAt, beforeResume.startedAt)
        XCTAssertEqual(afterResume.budget.deadline, deadline)
        XCTAssertEqual(afterResume.budget.maximumProviderRounds, 3)
        XCTAssertEqual(afterResume.budget.maximumToolCalls, 2)
        XCTAssertEqual(afterResume.resumeCount, 1)
        XCTAssertEqual(afterResume.state, .failed)
        XCTAssertEqual(afterResume.consumption.providerRoundsUsed, 3)
        XCTAssertEqual(afterResume.consumption.toolCallsUsed, 2)
        XCTAssertEqual(afterResume.consumption.inputTokens, 60)
        XCTAssertEqual(afterResume.consumption.cachedInputTokens, 15)
        XCTAssertEqual(afterResume.consumption.outputTokens, 18)
        XCTAssertEqual(afterResume.consumption.reasoningTokens, 5)
        XCTAssertEqual(resumedProvider.recordedRequests().count, 1)
        let resumedRequest = try XCTUnwrap(resumedProvider.recordedRequests().first)
        let resumedUserText = resumedRequest.messages
            .flatMap { $0.content.compactMap { content -> String? in
                if case .text(let text) = content { return text }
                return nil
            } }
            .joined(separator: "\n")
        XCTAssertTrue(resumedUserText.contains("恢复预算请求"))
        XCTAssertFalse(resumedUserText.contains("ignored replay text"))
        XCTAssertFalse(resumedRequest.messages.contains { message in
            message.content.contains { content in
                if case .toolCall = content { return true }
                if case .toolResult = content { return true }
                if case .reasoning = content { return true }
                return false
            }
        })

        let context = ModelContext(container)
        let userMessages = try context.fetch(FetchDescriptor<MessageRecord>())
            .filter { $0.requestID == requestID && $0.roleRaw == ModelRole.user.rawValue }
        XCTAssertEqual(userMessages.count, 1)
    }

    func testLegacyV1ConversationRestoresWithCurrentToolsAndAdvancesOnNewTurn() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV8.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000911")!
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000912")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = ModelContext(container)
        context.insert(ConversationRecord(id: conversationID))
        context.insert(MessageRecord(
            conversationID: conversationID,
            roleRaw: ModelRole.user.rawValue,
            contentData: try JSONEncoder().encode(ModelMessage(role: .user, text: "旧版对话内容")),
            ordinal: 0,
            requestID: requestID
        ))
        context.insert(AgentRequestRecord(
            requestID: requestID,
            conversationID: conversationID,
            startedAt: startedAt,
            absoluteDeadline: startedAt.addingTimeInterval(120),
            maximumProviderRounds: 3,
            maximumToolCalls: 2,
            containsTransientImage: false,
            stateRaw: AgentRequestState.interrupted.rawValue
        ))
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let legacyVersion = try await repository.toolSchemaVersion(conversationID: conversationID)
        XCTAssertEqual(legacyVersion, ToolSchemaVersion.legacy)

        let provider = ScriptedTextProvider(scripts: [[
            .textDelta("已安全恢复。"),
            .completed(.completed),
        ]])
        let session = makeSession(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            budget: AgentBudget(maximumProviderRounds: 4, maximumToolCalls: 4, deadline: .distantFuture)
        )
        try await session.restore()
        let response = try await session.send(userText: "继续", requestID: requestID)

        XCTAssertEqual(response.text, "已安全恢复。")
        let currentVersion = try await repository.toolSchemaVersion(conversationID: conversationID)
        XCTAssertEqual(currentVersion, ToolSchemaVersion.current)
        let request = try XCTUnwrap(provider.recordedRequests().first)
        let resumedUserText = request.messages
            .flatMap { $0.content.compactMap { content -> String? in
                if case .text(let text) = content { return text }
                return nil
            } }
            .joined(separator: "\n")
        XCTAssertTrue(resumedUserText.contains("旧版对话内容"))
    }

    func testV4StoreMigratesToV5AndAddsAnEmptyRequestLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-agent-request-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        try createV4Store(at: storeURL)

        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationTestPlanV5.self,
            configurations: [configuration]
        )
        let context = ModelContext(container)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ConversationRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MessageRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRequestRecord>()), 0)
    }

    func testRestoredTrackerKeepsCumulativeUsageAndOriginalDeadline() throws {
        let deadline = Date(timeIntervalSince1970: 2_100)
        var tracker = AgentBudgetTracker(
            budget: AgentBudget(maximumProviderRounds: 5, maximumToolCalls: 8, deadline: deadline),
            consumption: AgentBudgetConsumption(
                providerRoundsUsed: 2,
                toolCallsUsed: 3,
                inputTokens: 100,
                cachedInputTokens: 20,
                outputTokens: 30,
                reasoningTokens: 10
            )
        )

        XCTAssertEqual(tracker.remainingProviderRounds, 3)
        XCTAssertEqual(tracker.remainingToolCalls, 5)
        XCTAssertEqual(tracker.budget.deadline, deadline)
        try tracker.consumeProviderRound(now: deadline.addingTimeInterval(-1))
        try tracker.consumeToolCall(now: deadline.addingTimeInterval(-1))
        tracker.record(AgentTokenUsage(inputTokens: 10, cachedInputTokens: 4, outputTokens: 5, reasoningTokens: 2))

        XCTAssertEqual(tracker.providerRounds, 3)
        XCTAssertEqual(tracker.toolCalls, 4)
        XCTAssertEqual(tracker.consumption.inputTokens, 110)
        XCTAssertEqual(tracker.consumption.cachedInputTokens, 24)
        XCTAssertEqual(tracker.consumption.outputTokens, 35)
        XCTAssertEqual(tracker.consumption.reasoningTokens, 12)
        XCTAssertThrowsError(try tracker.requireTime(now: deadline))
    }

    private func makeSession(
        container: ModelContainer,
        repository: SwiftDataAgentRepository,
        provider: any TextModelProvider,
        conversationID: UUID,
        budget: AgentBudget
    ) -> AgentSession {
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        return AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            registry: ToolRegistry(),
            confirmationCoordinator: ConfirmationCoordinator(
                repository: confirmationRepository,
                writeGate: PersistenceWriteGate(state: .writable)
            ),
            readRepository: repository,
            conversationRepository: repository,
            conversationID: conversationID,
            budgetFactory: { budget }
        )
    }

    private func createV4Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000903")!
        context.insert(ConversationRecord(id: conversationID))
        context.insert(MessageRecord(
            conversationID: conversationID,
            roleRaw: ModelRole.user.rawValue,
            contentData: Data("persisted before V5".utf8),
            ordinal: 0
        ))
        try context.save()
    }
}
