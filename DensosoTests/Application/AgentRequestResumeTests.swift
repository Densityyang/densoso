import Foundation
import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class AgentRequestResumeTests: XCTestCase {
    func testConsentRevokedDuringFinalProviderGatePreventsStartingStream() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000940")!
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let governance = RevokesSleepOnSecondHealthTextCheckRepository()
        let provider = ScriptedTextProvider(
            scripts: [[.textDelta("本机不应把已撤销的睡眠上下文交给 provider。"), .completed(.completed)]],
            capabilities: [.text, .toolCalling, .structuredOutput]
        )
        let window = HealthContextWindowSummary(
            windowDays: 7,
            coverageDays: ["sleep": 7],
            averageSleepMinutes: 420,
            averageStepCount: nil,
            averageActiveEnergyKcal: nil,
            averageEnergyIntakeKcal: nil,
            averageDailyDeficitKcal: nil,
            averageProteinGrams: nil,
            medianWeightKilograms: nil
        )
        let summary = HealthContextSummary(
            sevenDay: window,
            twentyEightDay: window,
            targetWeightKilograms: nil,
            dailyDeficitGoalKcal: nil,
            dailyProteinGoalGrams: nil,
            recommendationReferences: []
        )
        let narrativeContext = HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "sleep.pre-send-sentinel", source: "sleep")],
            recommendationCandidates: [],
            aggregateSummary: summary
        )
        let session = makeSession(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            budget: AgentBudget(deadline: .distantFuture),
            governance: governance,
            healthNarrativeContextProvider: { narrativeContext }
        )

        do {
            _ = try await session.send(userText: "分析我的睡眠趋势怎么样", requestID: UUID())
            XCTFail("Revoked health context must be blocked before provider.stream is called")
        } catch {
            XCTAssertEqual(
                error as? ProviderError,
                .consentRequired(provider: .deepSeek, dataClass: .healthSleep)
            )
        }

        XCTAssertTrue(provider.recordedRequests().isEmpty)
    }

    func testAgentHealthPolicyAlignmentStagesDraftAndRequiresConversationConfirmation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000939")!
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let governance = SwiftDataProviderGovernanceRepository(modelContainer: container)
        try await governance.setConsent(
            provider: .deepSeek,
            dataClass: .healthText,
            granted: true,
            policyVersion: "cloud-health-text-v1"
        )
        let provider = ScriptedTextProvider(scripts: [], capabilities: [.text, .toolCalling, .structuredOutput])
        let session = makeSession(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            budget: AgentBudget(deadline: .distantFuture),
            governance: governance
        )

        let proposal = try await session.send(
            userText: "我授权你使用睡眠历史分析",
            requestID: UUID()
        )
        XCTAssertTrue(proposal.text.contains("回复“确认”启用"))
        let draft = try await governance.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        XCTAssertEqual(draft.state, .draft)
        XCTAssertEqual(draft.allowedClasses, [.healthSleep])
        let draftPolicy = try await CloudHealthContextPolicy.load(from: governance, provider: .deepSeek)
        XCTAssertFalse(draftPolicy.allows(.healthSleep))
        XCTAssertTrue(provider.recordedRequests().isEmpty)

        let confirmation = try await session.send(userText: "确认", requestID: UUID())
        XCTAssertTrue(confirmation.text.contains("已确认云端健康上下文策略"))
        let active = try await governance.currentCloudHealthContextPolicySnapshot(provider: .deepSeek)
        XCTAssertEqual(active.state, .active)
        XCTAssertEqual(active.allowedClasses, [.healthSleep])
        XCTAssertNotNil(active.confirmedAt)
        XCTAssertTrue(provider.recordedRequests().isEmpty)
    }

    func testConversationHistoryConsentDefaultsToCurrentTurnOnlyInProviderPayload() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let provider = ScriptedTextProvider(scripts: [
            [.textDelta("prior assistant private-history-secret"), .completed(.completed)],
            [.textDelta("仅看本轮输入。"), .completed(.completed)],
        ])
        let session = makeSession(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000938")!,
            budget: AgentBudget(deadline: .distantFuture),
            governance: governance
        )

        _ = try await session.send(userText: "prior user private-history-secret", requestID: UUID())
        _ = try await session.send(userText: "current turn only", requestID: UUID())

        let requests = provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let secondRequestText = try XCTUnwrap(requests.last).messages
            .flatMap { message in
                message.content.compactMap { content -> String? in
                    if case .text(let text) = content { return text }
                    if case .toolResult(_, let text) = content { return text }
                    return nil
                }
            }
            .joined(separator: "\n")
        XCTAssertTrue(secondRequestText.contains("current turn only"))
        XCTAssertFalse(secondRequestText.contains("private-history-secret"))
        XCTAssertFalse(secondRequestText.contains("prior assistant"))
    }

    func testConfirmedConversationHistoryConsentIncludesCurrentRevisionHistoryInProviderPayload() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV11.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let governance = SwiftDataProviderGovernanceRepository(modelContainer: container)
        try await governance.setConsent(
            provider: .deepSeek,
            dataClass: .healthText,
            granted: true,
            policyVersion: "cloud-health-text-v1"
        )
        _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
            provider: .deepSeek,
            allowed: true,
            repository: governance,
            confirmedAt: Date(timeIntervalSince1970: 1_798_100_100),
            changeSource: .settings
        )
        let confirmedPolicy = try await CloudHealthContextPolicy.load(
            from: governance,
            provider: .deepSeek
        )
        XCTAssertTrue(confirmedPolicy.allowsConversationHistory)

        let provider = ScriptedTextProvider(scripts: [
            [.textDelta("previous ordinary assistant reply"), .completed(.completed)],
            [.textDelta("current reply"), .completed(.completed)],
        ])
        let session = makeSession(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000942")!,
            budget: AgentBudget(deadline: .distantFuture),
            governance: governance
        )

        _ = try await session.send(userText: "previous ordinary user message", requestID: UUID())
        let policyAfterFirstTurn = try await CloudHealthContextPolicy.load(
            from: governance,
            provider: .deepSeek
        )
        XCTAssertEqual(policyAfterFirstTurn.revision, confirmedPolicy.revision)

        _ = try await session.send(userText: "current user message", requestID: UUID())

        let requests = provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let secondRequestText = try XCTUnwrap(requests.last).messages
            .flatMap { message in
                message.content.compactMap { content -> String? in
                    if case .text(let text) = content { return text }
                    if case .toolResult(_, let text) = content { return text }
                    return nil
                }
            }
            .joined(separator: "\n")
        XCTAssertTrue(secondRequestText.contains("previous ordinary user message"))
        XCTAssertTrue(secondRequestText.contains("previous ordinary assistant reply"))
        XCTAssertTrue(secondRequestText.contains("current user message"))
    }

    func testPolicyRevocationDuringHealthToolExecutionFiltersTheContinuationRequest() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000941")!
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(granted: [
            (.deepSeek, .healthText),
            (.deepSeek, .healthSleep),
            (.deepSeek, .healthActivity),
        ])
        let now = Date()
        let provider = ScriptedTextProvider(scripts: [
            [
                .textDelta("sleep.current-turn-prose-secret"),
                .toolCall(ToolCall(
                    id: "health-history-revocation",
                    name: "get_today_health_state",
                    arguments: .object([:])
                )),
                .completed(.toolUse),
            ],
            [.textDelta("已按当前授权继续。"), .completed(.completed)],
        ])
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 42,
            median: 600,
            p10: 500,
            p90: 700,
            mad: 30
        )
        let state = HealthStateV2(
            domains: [
                HealthDomainResult(
                    domain: .sleep,
                    status: .attention,
                    currentValue: 919_191,
                    baseline: baseline,
                    evidenceKeys: ["sleep.revoked-value-sentinel"]
                ),
                HealthDomainResult(
                    domain: .activity,
                    status: .withinTypicalRange,
                    currentValue: 606_060,
                    baseline: baseline,
                    evidenceKeys: ["activity.allowed-value-sentinel"]
                ),
            ],
            recovery: RecoveryAssessment(
                status: .attention,
                confidence: .high,
                evidence: [EvidenceReference(key: "sleep.recovery-provenance-sentinel", source: "sleep")],
                recommendedAction: .rest
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 707_070,
                priorTwentyEightDayAverage: 80,
                ratio: 8_838.38,
                readiness: .mature,
                band: .sharplyIncreased,
                estimatedWorkoutCount: 7,
                unavailableEffortCount: 0
            ),
            tomorrowGuidance: NextDayGuidance(
                expectedState: .caution,
                confidence: .high,
                reasons: [EvidenceReference(key: "sleep.guidance-provenance-sentinel", source: "sleep")],
                recommendedAction: .rest,
                conditionalNote: "sleep.revoked-derived-sentinel"
            )
        )
        let registry = ToolRegistry(todayHealthStateProvider: { _ in
            try await governance.setConsent(
                provider: .deepSeek,
                dataClass: .healthSleep,
                granted: false,
                policyVersion: "cloud-health-context-v1"
            )
            return state
        })
        let session = makeSession(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            budget: AgentBudget(deadline: .distantFuture),
            governance: governance,
            registry: registry
        )

        let response = try await session.send(userText: "继续读取", requestID: UUID())

        XCTAssertEqual(response.text, "已按当前授权继续。")
        let requests = provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let continuationText = try XCTUnwrap(requests.last).messages
            .flatMap { message in
                message.content.compactMap { content -> String? in
                    if case .text(let value) = content { return value }
                    if case .toolResult(_, let value) = content { return value }
                    return nil
                }
            }
            .joined(separator: "\n")
        XCTAssertFalse(continuationText.contains("sleep.revoked-value-sentinel"))
        XCTAssertFalse(continuationText.contains("sleep.current-turn-prose-secret"))
        XCTAssertFalse(continuationText.contains("sleep.recovery-provenance-sentinel"))
        XCTAssertFalse(continuationText.contains("sleep.guidance-provenance-sentinel"))
        XCTAssertFalse(continuationText.contains("919191"))
        XCTAssertFalse(continuationText.contains("sleep.revoked-derived-sentinel"))
        XCTAssertTrue(continuationText.contains("activity.allowed-value-sentinel"))
        XCTAssertTrue(continuationText.contains("606060"))
    }

    func testPerRequestCostReservationPersistsAndCannotResetOnResume() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000919")!
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000920")!
        let startedAt = Date()
        let firstRepository = SwiftDataAgentRepository(modelContainer: container)
        _ = try await firstRepository.beginAgentRequest(
            requestID: requestID,
            conversationID: conversationID,
            initialBudget: AgentBudget(maximumCostMicros: 5_000, deadline: startedAt.addingTimeInterval(120)),
            startedAt: startedAt,
            containsTransientImage: false
        )

        let firstReservation = try await firstRepository.reserveAgentRequestCost(
            requestID: requestID,
            conversationID: conversationID,
            provider: .deepSeek,
            model: "deepseek-flash",
            currency: "USD",
            pricingVersion: "cost-reservation-fixture-v1",
            providerRound: 1,
            estimatedCostMicros: 3_500
        )

        XCTAssertEqual(firstReservation.reservedCostMicros, 3_500)
        XCTAssertEqual(try XCTUnwrap(firstReservation.remainingCostMicros), 1_500)
        let resumedRepository = SwiftDataAgentRepository(modelContainer: container)
        let resumed = try await resumedRepository.beginAgentRequest(
            requestID: requestID,
            conversationID: conversationID,
            initialBudget: AgentBudget(maximumCostMicros: Int64.max, deadline: .distantFuture),
            startedAt: Date(),
            containsTransientImage: false
        )
        XCTAssertEqual(resumed.budget.maximumCostMicros, 5_000)
        XCTAssertEqual(resumed.costBudget.reservedCostMicros, 3_500)
        XCTAssertEqual(try XCTUnwrap(resumed.costBudget.remainingCostMicros), 1_500)
        let resumedSameRound = try await resumedRepository.reserveAgentRequestCost(
            requestID: requestID,
            conversationID: conversationID,
            provider: .deepSeek,
            model: "deepseek-flash",
            currency: "USD",
            pricingVersion: "cost-reservation-fixture-v1",
            providerRound: 1,
            estimatedCostMicros: 1_000
        )
        XCTAssertEqual(resumedSameRound.reservedCostMicros, 3_500)

        do {
            _ = try await resumedRepository.reserveAgentRequestCost(
                requestID: requestID,
                conversationID: conversationID,
                provider: .deepSeek,
                model: "deepseek-flash",
                currency: "USD",
                pricingVersion: "cost-reservation-fixture-v1",
                providerRound: 2,
                estimatedCostMicros: 2_000
            )
            XCTFail("A resumed request must not exceed its persisted cost cap")
        } catch {
            XCTAssertEqual(error as? AgentRequestPersistenceError, .costBudgetExceeded)
        }
        let afterAttempt = try await resumedRepository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(afterAttempt?.costBudget.reservedCostMicros, 3_500)
    }

    func testLegacyInterruptedRequestWithoutProviderIdentityFailsClosedBeforeCall() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000929")!
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000930")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = ModelContext(container)
        context.insert(ConversationRecord(id: conversationID))
        context.insert(MessageRecord(
            conversationID: conversationID,
            roleRaw: ModelRole.user.rawValue,
            contentData: try JSONEncoder().encode(ModelMessage(role: .user, text: "旧请求")),
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
            providerRoundsUsed: 1,
            inputTokens: 40,
            outputTokens: 12,
            stateRaw: AgentRequestState.interrupted.rawValue
        ))
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let provider = ScriptedTextProvider(scripts: [[.textDelta("不得发送"), .completed(.completed)]])
        let session = makeSession(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            budget: AgentBudget(maximumProviderRounds: 20, maximumToolCalls: 20, deadline: .distantFuture)
        )
        try await session.restore()

        do {
            _ = try await session.send(userText: "继续", requestID: requestID)
            XCTFail("Legacy requests without provider identity must not silently switch on resume")
        } catch {
            XCTAssertEqual(error as? ProviderError, .requestModelMismatch)
        }

        XCTAssertTrue(provider.recordedRequests().isEmpty)
        let requestValue = try await repository.agentRequest(requestID: requestID, conversationID: conversationID)
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(request.state, .failed)
        XCTAssertEqual(request.costBudget.state, .unavailable)
    }

    func testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
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
        let interruptedProvider = ScriptedTextProvider(model: "resume-test", scripts: [
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
        XCTAssertEqual(beforeResume.costBudget.state, .estimated)
        XCTAssertGreaterThan(beforeResume.costBudget.reservedCostMicros, 0)

        // Recreate the repository/session as after process restoration. A larger
        // factory budget must not replace the request's original limits/deadline.
        let resumedRepository = SwiftDataAgentRepository(modelContainer: container)
        let resumedProvider = ScriptedTextProvider(model: "resume-test", scripts: [[
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
        XCTAssertEqual(afterResume.costBudget.maximumCostMicros, beforeResume.costBudget.maximumCostMicros)
        XCTAssertGreaterThan(afterResume.costBudget.reservedCostMicros, beforeResume.costBudget.reservedCostMicros)
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
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
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
        budget: AgentBudget,
        governance: (any ProviderGovernanceRepository)? = nil,
        registry: ToolRegistry? = nil,
        healthNarrativeContextProvider: (@Sendable () async throws -> HealthNarrativeContext?)? = nil
    ) -> AgentSession {
        let confirmationRepository = SwiftDataConfirmationRepository(modelContainer: container)
        let resolvedGovernance: any ProviderGovernanceRepository = governance
            ?? InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        return AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: resolvedGovernance,
            usageLedger: ProviderUsageLedger(repository: resolvedGovernance, pricingDescriptorSource: TestPricingDescriptorCatalog.source),
            registry: registry ?? ToolRegistry(),
            confirmationCoordinator: ConfirmationCoordinator(
                repository: confirmationRepository,
                writeGate: PersistenceWriteGate(state: .writable)
            ),
            readRepository: repository,
            conversationRepository: repository,
            conversationID: conversationID,
            budgetFactory: { budget },
            healthNarrativeContextProvider: healthNarrativeContextProvider
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

private actor RevokesSleepOnSecondHealthTextCheckRepository: ProviderGovernanceRepository {
    private var granted = Set(CloudHealthContextPolicy.dataClasses).union([.healthText])
    private var healthTextChecks = 0

    func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass) -> Bool {
        guard provider == .deepSeek else { return false }
        let wasGranted = granted.contains(dataClass)
        if dataClass == .healthText {
            healthTextChecks += 1
            if healthTextChecks == 2 {
                granted.remove(.healthSleep)
            }
        }
        return wasGranted
    }

    func setConsent(
        provider: ProviderID,
        dataClass: ProviderDataClass,
        granted: Bool,
        policyVersion: String
    ) {
        guard provider == .deepSeek else { return }
        if granted { self.granted.insert(dataClass) } else { self.granted.remove(dataClass) }
    }

    func recordUsage(
        usage: ProviderUsage,
        usageKey: String,
        requestID: UUID,
        estimatedCostMicros: Int64?,
        currency: String?,
        rateVersion: String
    ) -> Bool {
        false
    }

    func monthlyUsage(
        provider: ProviderID,
        monthStart: Date,
        monthEnd: Date
    ) -> ProviderUsageSummary {
        ProviderUsageSummary(
            provider: provider,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            imageCount: 0,
            audioSeconds: 0,
            averageLatencyMilliseconds: nil,
            estimatedCostMicros: nil,
            currency: nil
        )
    }
}
