import Foundation
import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class MultimodalAgentImageTests: XCTestCase {
    private let imageBytes = Data([0xFF, 0xD8, 0xFF] + Array("PRIVATE-IMAGE-BYTES".utf8))
    private let privateOCRText = "PRIVATE-OCR-EVIDENCE-MUST-NOT-PERSIST"

    func testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence() async throws {
        let usage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture-model",
            capability: .vision,
            inputTokens: 30,
            outputTokens: 12,
            audioSeconds: 0,
            attempt: 1
        )
        let provider = ScriptedTextProvider(
            scripts: [
                [
                    .toolCall(mealCall()),
                    .usage(usage),
                    .completed(.toolUse),
                ],
                [.textDelta("照片餐食草稿已准备，请确认。"), .completed(.completed)],
            ],
            capabilities: [.text, .toolCalling, .vision]
        )
        let harness = try makeHarness(provider: provider, grantMealImage: true)
        let supplementalText = "配菜只有少量，不要额外加辣椒。"
        let request = try imageRequest().includingSupplementalText(supplementalText)
        let requestID = UUID()

        _ = try await harness.session.send(multimodalRequest: request, requestID: requestID)

        XCTAssertEqual(harness.session.pendingActions.count, 1)
        guard case .meal(let meal) = try XCTUnwrap(harness.session.pendingActions.first).payload else {
            return XCTFail("Agent image meal input must produce a meal pending action")
        }
        let imageEvidence = try XCTUnwrap(meal.dishes.first?.ingredients.first?.evidence.first {
            $0.sourceID == "agent-image:nutritionLabel"
        })
        XCTAssertEqual(imageEvidence.summary, "本机图像线索已附加，提取文本未保存")

        let requests = provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].messages.contains { message in
            message.content.contains { content in
                if case .image = content { return true }
                return false
            }
        })
        let userMessages = requests[0].messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1)
        XCTAssertTrue(userMessages[0].content.contains { content in
            if case .text(let text) = content { return text.contains(supplementalText) }
            return false
        })
        XCTAssertTrue(userMessages[0].content.contains { content in
            if case .image = content { return true }
            return false
        })

        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
        let storedMessages = try context.fetch(FetchDescriptor<MessageRecord>())
        let storedText = storedMessages.compactMap { String(data: $0.contentData, encoding: .utf8) }.joined()
        XCTAssertTrue(storedText.contains(supplementalText))
        XCTAssertFalse(storedText.contains(request.image!.base64Data))
        XCTAssertFalse(storedText.contains("PRIVATE-IMAGE-BYTES"))
        XCTAssertFalse(storedText.contains(privateOCRText))

        let actionJSON = String(
            data: try harness.session.pendingActions[0].payload.canonicalData(),
            encoding: .utf8
        )!
        XCTAssertFalse(actionJSON.contains(privateOCRText))
        XCTAssertFalse(actionJSON.contains("PRIVATE-IMAGE-BYTES"))
        XCTAssertTrue(actionJSON.contains("agent-image:nutritionLabel"))

        let requestRecordValue = try await harness.repository.agentRequest(
            requestID: requestID,
            conversationID: harness.conversationID
        )
        let requestRecord = try XCTUnwrap(requestRecordValue)
        XCTAssertTrue(requestRecord.containsTransientImage)
    }

    func testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget() async throws {
        let requestID = UUID()
        let conversationID = UUID()
        let deadline = Date().addingTimeInterval(120)
        let firstUsage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture-model",
            capability: .vision,
            inputTokens: 40,
            outputTokens: 10,
            audioSeconds: 0,
            attempt: 1,
            cachedInputTokens: 8,
            reasoningTokens: 2
        )
        let initialProvider = ScriptedTextProvider(
            scripts: [[.usage(firstUsage), .completed(.completed)]],
            capabilities: [.text, .toolCalling, .vision]
        )
        let initialHarness = try makeHarness(
            provider: initialProvider,
            grantMealImage: true,
            conversationID: conversationID,
            budgetFactory: {
                AgentBudget(maximumProviderRounds: 2, maximumToolCalls: 4, deadline: deadline)
            }
        )
        let request = try imageRequest()

        do {
            _ = try await initialHarness.session.send(multimodalRequest: request, requestID: requestID)
            XCTFail("An empty image response must interrupt the request")
        } catch {
            XCTAssertEqual(error as? AgentError, .emptyResponse)
        }

        let beforeResumeValue = try await initialHarness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let beforeResume = try XCTUnwrap(beforeResumeValue)
        XCTAssertTrue(beforeResume.containsTransientImage)
        XCTAssertEqual(beforeResume.state, .interrupted)
        XCTAssertEqual(beforeResume.budget.deadline, deadline)
        XCTAssertEqual(beforeResume.consumption.providerRoundsUsed, 1)
        XCTAssertEqual(beforeResume.consumption.inputTokens, 40)

        let resumeProvider = ScriptedTextProvider(
            scripts: [[
                .textDelta("已根据重新附加的照片生成草稿。"),
                .usage(ProviderUsage(
                    provider: .deepSeek,
                    model: "fixture-model",
                    capability: .vision,
                    inputTokens: 5,
                    outputTokens: 3,
                    audioSeconds: 0,
                    attempt: 1
                )),
                .completed(.completed),
            ]],
            capabilities: [.text, .toolCalling, .vision]
        )
        let resumedHarness = try makeHarness(
            provider: resumeProvider,
            grantMealImage: true,
            conversationID: conversationID,
            budgetFactory: { AgentBudget(maximumProviderRounds: 10, maximumToolCalls: 10, deadline: .distantFuture) }
        )
        try await resumedHarness.session.restore()

        do {
            _ = try await resumedHarness.session.send(userText: "继续", requestID: requestID)
            XCTFail("A transient-image request must not resume from text alone")
        } catch {
            XCTAssertEqual(error as? AgentError, .transientImageRequired)
        }
        XCTAssertTrue(resumeProvider.recordedRequests().isEmpty)
        let blockedResumeValue = try await resumedHarness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let blockedResume = try XCTUnwrap(blockedResumeValue)
        XCTAssertEqual(blockedResume.resumeCount, 0)
        XCTAssertEqual(blockedResume.consumption.providerRoundsUsed, 1)

        _ = try await resumedHarness.session.send(multimodalRequest: request, requestID: requestID)

        let resumedRequest = try XCTUnwrap(resumeProvider.recordedRequests().first)
        XCTAssertTrue(resumedRequest.messages.contains { message in
            message.content.contains { content in
                if case .image = content { return true }
                return false
            }
        })
        let afterResumeValue = try await resumedHarness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let afterResume = try XCTUnwrap(afterResumeValue)
        XCTAssertEqual(afterResume.resumeCount, 1)
        XCTAssertEqual(afterResume.budget.maximumProviderRounds, 2)
        XCTAssertEqual(afterResume.budget.deadline, deadline)
        XCTAssertEqual(afterResume.consumption.providerRoundsUsed, 2)
        XCTAssertEqual(afterResume.consumption.inputTokens, 45)

        let context = ModelContext(resumedHarness.container)
        let persisted = try context.fetch(FetchDescriptor<MessageRecord>())
            .compactMap { String(data: $0.contentData, encoding: .utf8) }
            .joined()
        XCTAssertFalse(persisted.contains(request.image!.base64Data))
        XCTAssertFalse(persisted.contains(privateOCRText))
        let requestRecordValue = try await resumedHarness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let requestRecord = try XCTUnwrap(requestRecordValue)
        XCTAssertTrue(requestRecord.containsTransientImage)
    }

    func testImageRequiresVisionCapabilityAndSeparateMealImageConsent() async throws {
        let request = try imageRequest()
        let noVisionProvider = ScriptedTextProvider(
            scripts: [[.textDelta("must not send"), .completed(.completed)]],
            capabilities: [.text, .toolCalling]
        )
        let visionHarness = try makeHarness(
            provider: noVisionProvider,
            grantMealImage: true
        )
        do {
            _ = try await visionHarness.session.send(multimodalRequest: request)
            XCTFail("A text-only provider must not receive the image")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unsupportedCapability(.vision))
        }
        XCTAssertTrue(noVisionProvider.recordedRequests().isEmpty)

        let noConsentProvider = ScriptedTextProvider(
            scripts: [[.textDelta("must not send"), .completed(.completed)]],
            capabilities: [.text, .toolCalling, .vision]
        )
        let consentHarness = try makeHarness(provider: noConsentProvider, grantMealImage: false)
        do {
            _ = try await consentHarness.session.send(multimodalRequest: request)
            XCTFail("Image upload requires separate meal-image consent")
        } catch {
            XCTAssertEqual(
                error as? ProviderError,
                .consentRequired(provider: .deepSeek, dataClass: .mealImage)
            )
        }
        XCTAssertTrue(noConsentProvider.recordedRequests().isEmpty)
    }

    private func imageRequest() throws -> MultimodalModelRequest {
        try MultimodalModelRequest(
            userText: "请根据照片记录餐食并准备待确认草稿。",
            imageJPEG: imageBytes,
            mealEvidence: [
                MealEvidence(
                    kind: .nutritionLabel,
                    value: privateOCRText,
                    confidence: 0.92,
                    sourceVersion: "fixture-ocr-v1"
                ),
            ]
        )
    }

    private func mealCall() -> ToolCall {
        ToolCall(
            id: "image-meal-tool",
            name: "log_meal",
            arguments: .object([
                "mealType": .string("lunch"),
                "occurredAt": .null,
                "dishes": .array([
                    .object([
                        "dishName": .string("米饭"),
                        "cookingMethod": .string("stirFry"),
                        "ingredients": .array([
                            .object([
                                "name": .string("米饭(熟)"),
                                "amountGrams": .number(150),
                                "preparation": .string("cooked"),
                                "massBasis": .string("cooked"),
                            ]),
                        ]),
                        "notedOilG": .null,
                        "lowConfidence": .boolean(false),
                    ]),
                ]),
                "note": .null,
            ])
        )
    }

    private func makeHarness(
        provider: ScriptedTextProvider,
        grantMealImage: Bool,
        conversationID: UUID = UUID(),
        budgetFactory: @escaping @Sendable () -> AgentBudget = { AgentBudget() }
    ) throws -> ImageAgentHarness {
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(
            granted: grantMealImage
                ? [(.deepSeek, .healthText), (.deepSeek, .mealImage)]
                : [(.deepSeek, .healthText)]
        )
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        let confirmationCoordinator = ConfirmationCoordinator(
            repository: SwiftDataConfirmationRepository(modelContainer: container),
            writeGate: PersistenceWriteGate(state: .writable)
        )
        let session = AgentSession(
            providerSelector: TestProviderSelector(provider),
            intelligencePreferences: preferences,
            providerConfiguration: ProviderConfigurationPreferences(),
            governanceRepository: governance,
            usageLedger: ProviderUsageLedger(repository: governance),
            registry: ToolRegistry(),
            confirmationCoordinator: confirmationCoordinator,
            readRepository: repository,
            conversationRepository: repository,
            conversationID: conversationID,
            budgetFactory: budgetFactory
        )
        let foodDatabase = try FoodDatabase(seedJSON: Data(Self.foodSeed.utf8))
        session.foodDatabase = foodDatabase
        return ImageAgentHarness(
            container: container,
            session: session,
            repository: repository,
            foodDatabase: foodDatabase,
            conversationID: conversationID
        )
    }

    private static let foodSeed = """
    [{"id":2,"name":"米饭(熟)","alias":"熟米饭|白米饭","preparation":"cooked","category":"谷类及制品","edible":100,"energyKcal":116,"proteinG":2.6,"fatG":0.3,"carbohydrateG":25.9,"fiberG":0.3}]
    """
}

@MainActor
private struct ImageAgentHarness {
    let container: ModelContainer
    let session: AgentSession
    let repository: SwiftDataAgentRepository
    let foodDatabase: FoodDatabase
    let conversationID: UUID
}
