import DensosoDomain
import Network
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ToolExecutionJournalTests: XCTestCase {
    func testDeepSeekHTTPProviderStagesAndConfirmsActionInDiskStore() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let server = try await LocalHTTPTestServer.start(responses: [
            try Gate03FixtureLoader.data("deepseek-responses-stream", extension: "sse"),
            try Self.completedTextResponse("体重草稿已准备，等待你确认。"),
        ])
        defer { server.stop() }
        let container = try makeDiskContainer(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let conversationID = UUID()
        let provider = DeepSeekProvider(
            endpoint: server.endpoint,
            credentialSource: TestCredentialSource(values: [.deepSeek: "fixture"]),
            jitter: { _ in 0 }
        )
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID
        )
        let requestID = UUID()

        let response = try await harness.session.send(
            userText: "记录体重 62.5 千克",
            requestID: requestID
        )

        XCTAssertEqual(response.text, "体重草稿已准备，等待你确认。")
        XCTAssertEqual(harness.session.pendingActions.count, 1)
        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .weight(let draft) = action.payload else {
            return XCTFail("The decoded provider tool call must stage a weight action")
        }
        let requestSnapshot = try await repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let request = try XCTUnwrap(requestSnapshot)
        XCTAssertEqual(draft.kilograms, 62.5)
        XCTAssertEqual(draft.measuredAt, request.startedAt)

        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.first?.state, .completed)
        XCTAssertEqual(journal.first?.pendingActionID, action.id)

        let requests = server.recordedRequestBodies()
        XCTAssertEqual(requests.count, 2)
        let firstBody = try XCTUnwrap(requests.first)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        XCTAssertEqual(firstObject["model"] as? String, ProviderCapabilityCatalog.deepSeekFlashModel)
        XCTAssertTrue(String(decoding: firstBody, as: UTF8.self).contains("log_weight"))
        XCTAssertTrue(String(decoding: firstBody, as: UTF8.self).contains("记录体重 62.5 千克"))
        let secondBody = try XCTUnwrap(requests.last)
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let secondInput = try XCTUnwrap(secondObject["input"] as? [[String: Any]])
        XCTAssertTrue(secondInput.contains { $0["type"] as? String == "function_call_output" })

        _ = try await harness.session.confirmPendingAction(action)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<WeightRecord>()), 1)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 1)
    }

    func testResumeAfterStagedWeightActionDoesNotCreateDuplicatePendingAction() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let requestID = UUID()
        let conversationID = UUID()
        let call = weightCall()
        let userText = "记录体重 62.5kg"

        try await interruptAfterStaging(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: userText,
            call: call,
            leadingReadOnlyRound: true
        )
        let harness = try await resume(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: userText,
            call: call
        )

        XCTAssertEqual(harness.session.pendingActions.count, 1)
        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .weight(let draft) = action.payload else {
            return XCTFail("Expected a pending weight action")
        }
        let requestSnapshot = try await harness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let request = try XCTUnwrap(requestSnapshot)
        XCTAssertEqual(draft.measuredAt, request.startedAt)
        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.first?.state, .completed)
        XCTAssertEqual(journal.first?.pendingActionID, action.id)
        XCTAssertEqual(journal.first?.requestTimeAnchor, request.startedAt)

        _ = try await harness.session.confirmPendingAction(action)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<WeightRecord>()), 1)
    }

    func testToolCompletingAfterDeadlineCannotStageAction() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let container = try makeDiskContainer(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let slowPrior = SlowMealPortionPriorRepository(delayNanoseconds: 6_000_000_000)
        let requestID = UUID()
        let conversationID = UUID()
        let provider = ScriptedTextProvider(scripts: [[
            .toolCall(mealCall(id: "deadline-meal", mealType: "lunch")),
            .completed(.toolUse),
        ]])
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            needsFoodDatabase: true,
            mealPortionPriorRepository: slowPrior,
            budgetFactory: { AgentBudget(deadline: Date().addingTimeInterval(3)) }
        )

        do {
            _ = try await harness.session.send(userText: "我午餐吃了一碗米饭", requestID: requestID)
            XCTFail("The request should expire while meal preparation is waiting on local priors")
        } catch {
            XCTAssertEqual(error as? ProviderError, .timeout)
        }

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(journal.map(\.state), [.failed])
        let persistedRequest = try await repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let request = try XCTUnwrap(persistedRequest)
        XCTAssertEqual(request.state, .expired)
    }

    func testDeadlineExpirationDoesNotLeaveOrphanPendingAction() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let container = try makeDiskContainer(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let slowPrior = SlowMealPortionPriorRepository(delayNanoseconds: 4_000_000_000)
        let requestID = UUID()
        let conversationID = UUID()
        let provider = ScriptedTextProvider(scripts: [[
            .toolCall(mealCall(id: "orphan-meal", mealType: "dinner")),
            .completed(.toolUse),
        ]])
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            needsFoodDatabase: true,
            mealPortionPriorRepository: slowPrior,
            budgetFactory: { AgentBudget(deadline: Date().addingTimeInterval(2)) }
        )

        do {
            _ = try await harness.session.send(userText: "我晚餐吃了一碗米饭", requestID: requestID)
            XCTFail("An expired request must not leave a pending action")
        } catch {
            XCTAssertEqual(error as? ProviderError, .timeout)
        }

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        let persistedRequest = try await repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let request = try XCTUnwrap(persistedRequest)
        XCTAssertEqual(request.state, .expired)
        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertTrue(journal.allSatisfy { $0.state == .failed })
    }

    func testCancellationPropagatesIntoToolExecution() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let container = try makeDiskContainer(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let slowPrior = SlowMealPortionPriorRepository(delayNanoseconds: 60_000_000_000)
        let requestID = UUID()
        let conversationID = UUID()
        let provider = ScriptedTextProvider(scripts: [[
            .toolCall(mealCall(id: "cancel-meal", mealType: "lunch")),
            .completed(.toolUse),
        ]])
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            needsFoodDatabase: true,
            mealPortionPriorRepository: slowPrior
        )
        let requestTask = Task {
            try await harness.session.send(userText: "我午餐吃了一碗米饭", requestID: requestID)
        }
        await slowPrior.waitUntilDishPriorStarts()
        harness.session.cancelActiveRequest()
        do {
            _ = try await requestTask.value
            XCTFail("The cancelled request should stop in tool execution")
        } catch {
            XCTAssertEqual(error as? ProviderError, .cancelled)
        }

        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
        let persistedRequest = try await repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let request = try XCTUnwrap(persistedRequest)
        XCTAssertEqual(request.state, .interrupted)
        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(journal.map(\.state), [.failed])
    }

    func testCancellationDoesNotRejectAnotherRequestPendingAction() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let container = try makeDiskContainer(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let slowPrior = SlowMealPortionPriorRepository(delayNanoseconds: 60_000_000_000)
        let requestID = UUID()
        let conversationID = UUID()
        let provider = ScriptedTextProvider(scripts: [[
            .toolCall(mealCall(id: "cancel-meal", mealType: "lunch")),
            .completed(.toolUse),
        ]])
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            needsFoodDatabase: true,
            mealPortionPriorRepository: slowPrior
        )
        let requestTask = Task {
            try await harness.session.send(
                userText: "我午餐吃了一碗米饭",
                requestID: requestID
            )
        }
        await slowPrior.waitUntilDishPriorStarts()

        let unrelatedRequestID = UUID()
        let unrelatedAction = try await harness.confirmation.stage(
            payload: .weight(
                WeightDraft(
                    measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    kilograms: 64.5
                )
            ),
            clientRequestID: unrelatedRequestID,
            conversationID: conversationID
        )
        harness.session.cancelActiveRequest()
        do {
            _ = try await requestTask.value
            XCTFail("The cancelled request should stop in tool execution")
        } catch {
            XCTAssertEqual(error as? ProviderError, .cancelled)
        }

        let activeActions = try await harness.confirmation.activeActions(conversationID: conversationID)
        XCTAssertEqual(activeActions.map(\.id), [unrelatedAction.id])
        XCTAssertEqual(activeActions.first?.clientRequestID, unrelatedRequestID)
        XCTAssertEqual(activeActions.first?.state, .pending)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
    }

    func testResumeAfterStagedMealActionReplaysOriginalDraft() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let requestID = UUID()
        let conversationID = UUID()
        let call = mealCall(id: "meal-replay", mealType: "lunch")
        let userText = "我午餐吃了一碗米饭"

        try await interruptAfterStaging(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: userText,
            call: call,
            needsFoodDatabase: true
        )
        let harness = try await resume(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: userText,
            call: call,
            needsFoodDatabase: true
        )

        XCTAssertEqual(harness.session.pendingActions.count, 1)
        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a pending meal action")
        }
        let requestSnapshot = try await harness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let request = try XCTUnwrap(requestSnapshot)
        XCTAssertEqual(draft.occurredAt, request.startedAt)
        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.first?.state, .completed)
        XCTAssertEqual(journal.first?.pendingActionID, action.id)
        let expectedPayloadData = try ToolExecutionPayloadCodec.encode(action.payload)
        XCTAssertEqual(journal.first?.preparedPayloadData, expectedPayloadData)

        _ = try await harness.session.confirmPendingAction(action)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 1)
    }

    func testResumeAfterStagedCheckInDoesNotCreateDuplicateEntry() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let requestID = UUID()
        let conversationID = UUID()
        let call = checkInCall()
        let userText = "请记录我的每日状态：今天感觉特别累，压力很大，昨晚睡眠不好，备注昨晚醒了几次。"

        try await interruptAfterStaging(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: userText,
            call: call
        )
        let harness = try await resume(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: userText,
            call: call
        )

        XCTAssertEqual(harness.session.pendingActions.count, 1)
        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .dailyCheckIn(let draft) = action.payload else {
            return XCTFail("Expected a pending daily check-in action")
        }
        let requestSnapshot = try await harness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let request = try XCTUnwrap(requestSnapshot)
        XCTAssertEqual(draft.occurredAt, request.startedAt)
        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.first?.state, .completed)
        XCTAssertEqual(journal.first?.pendingActionID, action.id)

        _ = try await harness.session.confirmPendingAction(action)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<DailyCheckInRecord>()), 1)
    }

    func testSameRequestAllowsMultipleDistinctMealInvocations() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let requestID = UUID()
        let conversationID = UUID()
        let calls = [mealCall(id: "lunch", mealType: "lunch"), mealCall(id: "dinner", mealType: "dinner")]
        let userText = "我午餐和晚餐各吃了一碗米饭"
        let container = try makeDiskContainer(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let provider = ScriptedTextProvider(scripts: [
            calls.map(ProviderEvent.toolCall) + [.completed(.toolUse)],
            [.textDelta("已准备两份待确认餐食草稿。"), .completed(.completed)],
        ])
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            needsFoodDatabase: true
        )

        _ = try await harness.session.send(userText: userText, requestID: requestID)

        XCTAssertEqual(harness.session.pendingActions.count, 2)
        XCTAssertNotEqual(harness.session.pendingActions[0].id, harness.session.pendingActions[1].id)
        let journal = try await harness.confirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        XCTAssertEqual(journal.count, 2)
        XCTAssertEqual(journal.map(\.callIndex), [0, 1])
        XCTAssertEqual(Set(journal.map(\.invocationID)).count, 2)

        for action in harness.session.pendingActions {
            _ = try await harness.session.confirmPendingAction(action)
        }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<MealRecord>()), 2)
    }

    func testToolExecutionJournalSurvivesProcessRestart() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let requestID = UUID()
        let conversationID = UUID()
        let call = weightCall()

        try await interruptAfterStaging(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: "记录体重 62.5kg",
            call: call
        )

        // A fresh ModelContainer and repository model a new process opening the same disk store.
        let reopenedContainer = try makeDiskContainer(at: location.storeURL)
        let reopenedConfirmation = ConfirmationCoordinator(
            repository: SwiftDataConfirmationRepository(modelContainer: reopenedContainer),
            writeGate: PersistenceWriteGate(state: .writable)
        )
        let journal = try await reopenedConfirmation.toolExecutionJournal(
            requestID: requestID,
            conversationID: conversationID
        )
        let actions = try await reopenedConfirmation.activeActions(conversationID: conversationID)

        XCTAssertEqual(journal.count, 1)
        XCTAssertEqual(journal.first?.state, .completed)
        XCTAssertNotNil(journal.first?.pendingActionID)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.id, journal.first?.pendingActionID)
    }

    func testResumedInvocationWithChangedArgumentsFailsClosed() async throws {
        let location = try storeLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let requestID = UUID()
        let conversationID = UUID()
        let originalCall = weightCall()
        try await interruptAfterStaging(
            at: location.storeURL,
            requestID: requestID,
            conversationID: conversationID,
            userText: "记录体重 62.5kg",
            call: originalCall
        )

        let container = try makeDiskContainer(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let changedProvider = ScriptedTextProvider(scripts: [
            [.toolCall(weightCall(kilograms: 63)), .completed(.toolUse)],
        ])
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: changedProvider,
            conversationID: conversationID
        )
        try await harness.session.restore()

        do {
            _ = try await harness.session.send(userText: "继续", requestID: requestID)
            XCTFail("A changed tool payload must not inherit the original invocation")
        } catch {
            XCTAssertEqual(error as? ToolExecutionJournalError, .invocationIdentityMismatch)
        }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
    }

    private func interruptAfterStaging(
        at storeURL: URL,
        requestID: UUID,
        conversationID: UUID,
        userText: String,
        call: ToolCall,
        needsFoodDatabase: Bool = false,
        leadingReadOnlyRound: Bool = false
    ) async throws {
        var container: ModelContainer? = try makeDiskContainer(at: storeURL)
        var repository: SwiftDataAgentRepository? = SwiftDataAgentRepository(modelContainer: container!)
        var scripts: [[ProviderEvent]] = []
        if leadingReadOnlyRound {
            scripts.append([.toolCall(scheduleCall()), .completed(.toolUse)])
        }
        scripts.append([.toolCall(call), .completed(.toolUse)])
        scripts.append([.completed(.completed)])
        let provider = ScriptedTextProvider(scripts: scripts)
        var harness: JournalHarness? = makeHarness(
            container: container!,
            repository: repository!,
            provider: provider,
            conversationID: conversationID,
            needsFoodDatabase: needsFoodDatabase
        )

        do {
            _ = try await harness!.session.send(userText: userText, requestID: requestID)
            XCTFail("Expected the intentionally empty next provider round to interrupt the request")
        } catch {
            XCTAssertEqual(error as? AgentError, .emptyResponse)
        }

        harness = nil
        repository = nil
        container = nil
    }

    private func resume(
        at storeURL: URL,
        requestID: UUID,
        conversationID: UUID,
        userText: String,
        call: ToolCall,
        needsFoodDatabase: Bool = false
    ) async throws -> JournalHarness {
        let container = try makeDiskContainer(at: storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let provider = ScriptedTextProvider(scripts: [
            [.toolCall(call), .completed(.toolUse)],
            [.textDelta("已恢复并复用原待确认草稿。"), .completed(.completed)],
        ])
        let harness = makeHarness(
            container: container,
            repository: repository,
            provider: provider,
            conversationID: conversationID,
            needsFoodDatabase: needsFoodDatabase
        )
        try await harness.session.restore()
        _ = try await harness.session.send(userText: "继续", requestID: requestID)
        return harness
    }

    private func makeHarness(
        container: ModelContainer,
        repository: SwiftDataAgentRepository,
        provider: any TextModelProvider,
        conversationID: UUID,
        needsFoodDatabase: Bool = false,
        mealPortionPriorRepository: (any MealPortionPriorRepository)? = nil,
        budgetFactory: @escaping @Sendable () -> AgentBudget = { AgentBudget(deadline: .distantFuture) }
    ) -> JournalHarness {
        let confirmation = ConfirmationCoordinator(
            repository: SwiftDataConfirmationRepository(modelContainer: container),
            writeGate: PersistenceWriteGate(state: .writable)
        )
        let governance = InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        let session = AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(
                repository: governance,
                pricingDescriptorSource: TestPricingDescriptorCatalog.source
            ),
            registry: ToolRegistry(mealPortionPriorRepository: mealPortionPriorRepository),
            confirmationCoordinator: confirmation,
            readRepository: repository,
            conversationRepository: repository,
            conversationID: conversationID,
            budgetFactory: budgetFactory
        )
        let database = needsFoodDatabase ? try? FoodDatabase(seedJSON: Data(Self.foodSeed.utf8)) : nil
        session.foodDatabase = database
        return JournalHarness(
            container: container,
            repository: repository,
            confirmation: confirmation,
            session: session,
            foodDatabase: database
        )
    }

    private func makeDiskContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: storeURL)
        return try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private func storeLocation() throws -> (directory: URL, storeURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-tool-journal-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("default.store"))
    }

    private func weightCall(kilograms: Double = 62.5) -> ToolCall {
        ToolCall(
            id: "weight-call",
            name: "log_weight",
            arguments: .object([
                "kilograms": .number(kilograms),
                "measuredAt": .null,
            ])
        )
    }

    private static func completedTextResponse(_ text: String) throws -> Data {
        let encodedText = try JSONEncoder().encode(text)
        let jsonString = String(decoding: encodedText, as: UTF8.self)
        return Data(
            """
            event: response.completed
            data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":\(jsonString)}] }]}}

            """.utf8
        )
    }

    private func scheduleCall() -> ToolCall {
        ToolCall(
            id: "schedule-read",
            name: "get_schedule",
            arguments: .object(["date": .string("2026-11-03T00:00:00Z")])
        )
    }

    private func checkInCall() -> ToolCall {
        ToolCall(
            id: "checkin-call",
            name: "stage_daily_checkin",
            arguments: .object([
                "energy": .string("low"),
                "stress": .string("elevated"),
                "subjectiveSleep": .string("poor"),
                "occurredAt": .null,
                "note": .string("昨晚醒了几次"),
            ])
        )
    }

    private func mealCall(id: String, mealType: String) -> ToolCall {
        ToolCall(
            id: id,
            name: "log_meal",
            arguments: .object([
                "mealType": .string(mealType),
                "occurredAt": .null,
                "dishes": .array([
                    .object([
                        "dishName": .string("米饭"),
                        "cookingMethod": .string("unknown"),
                        "ingredients": .array([
                            .object([
                                "name": .string("米饭"),
                                "quantityEvidence": .object([
                                    "kind": .string("household"),
                                    "value": .number(1),
                                    "unit": .string("bowl"),
                                    "gramsPerServing": .null,
                                ]),
                                "preparation": .string("cooked"),
                                "massBasis": .string("cooked"),
                            ]),
                        ]),
                        "lowConfidence": .boolean(false),
                    ]),
                ]),
                "note": .null,
            ])
        )
    }

    private static let foodSeed = #"""
    [
      {"id":2,"name":"米饭(熟)","alias":"米饭|熟米饭|白米饭","preparation":"cooked","category":"谷类及制品","edible":100,"energyKcal":116,"proteinG":2.6,"fatG":0.3,"carbohydrateG":25.9,"fiberG":0.3}
    ]
    """#
}

private actor SlowMealPortionPriorRepository: MealPortionPriorRepository {
    private let delayNanoseconds: UInt64
    private var didStartDishPriorLookup = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func all() async throws -> [PersonalMealPortionPrior] { [] }
    func prior(foodID: String?, foodName: String, unit: String) async throws -> HouseholdPortionPrior? { nil }
    func save(_ edit: PersonalMealPortionPriorEdit) async throws {}
    func delete(id: UUID) async throws {}
    func allDishPriors() async throws -> [PersonalMealDishPrior] { [] }

    func dishPrior(named: String, cookingMethod: String?) async throws -> PersonalMealDishPrior? {
        didStartDishPriorLookup = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return nil
    }

    func saveDishPrior(_ edit: PersonalMealDishPriorEdit) async throws {}
    func deleteDishPrior(id: UUID) async throws {}

    func waitUntilDishPriorStarts() async {
        if didStartDishPriorLookup { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

@MainActor
private struct JournalHarness {
    let container: ModelContainer
    let repository: SwiftDataAgentRepository
    let confirmation: ConfirmationCoordinator
    let session: AgentSession
    let foodDatabase: FoodDatabase?
}

private final class LocalHTTPTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.densoso.tests.local-http-server")
    private let lock = NSLock()
    private let responses: [Data]
    private var responseIndex = 0
    private var requestBodies: [Data] = []
    private var readyContinuation: CheckedContinuation<URL, Error>?

    private init(responses: [Data]) throws {
        self.responses = responses
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start(responses: [Data]) async throws -> LocalHTTPTestServer {
        let server = try LocalHTTPTestServer(responses: responses)
        do {
            _ = try await server.startListening()
            return server
        } catch {
            server.stop()
            throw error
        }
    }

    var endpoint: URL {
        lock.withLock { startedEndpoint! }
    }

    private var startedEndpoint: URL?

    private func startListening() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { readyContinuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port,
                          let url = URL(string: "http://localhost:\(port.rawValue)/responses") else {
                        self.completeStartup(.failure(URLError(.badURL)))
                        return
                    }
                    self.lock.withLock { self.startedEndpoint = url }
                    self.completeStartup(.success(url))
                case .failed(let error):
                    self.completeStartup(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func completeStartup(_ result: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            defer { readyContinuation = nil }
            return readyContinuation
        }
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var accumulated = buffered
            if let data { accumulated.append(data) }
            if let requestBody = Self.parseRequestBody(accumulated) {
                let response = self.response(for: requestBody)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffered: accumulated)
            }
        }
    }

    private func response(for requestBody: Data) -> Data {
        let body = lock.withLock { () -> Data in
            requestBodies.append(requestBody)
            guard responses.indices.contains(responseIndex) else { return Data() }
            defer { responseIndex += 1 }
            return responses[responseIndex]
        }
        let header = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        return header + body
    }

    private static func parseRequestBody(_ request: Data) -> Data? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = request.range(of: separator) else { return nil }
        let headerData = request.subdata(in: request.startIndex..<headerRange.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let contentLengthLine = headerText
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
        let contentLength = contentLengthLine
            .flatMap { $0.split(separator: ":", maxSplits: 1).last }
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyStart = headerRange.upperBound
        guard request.count >= bodyStart + contentLength else { return nil }
        return request.subdata(in: bodyStart..<(bodyStart + contentLength))
    }

    func recordedRequestBodies() -> [Data] {
        lock.withLock { requestBodies }
    }

    func stop() {
        listener.cancel()
    }
}
