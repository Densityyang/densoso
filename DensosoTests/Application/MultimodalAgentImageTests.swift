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
            capability: .text,
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
        let request = try imageRequest().includingSupplementalText(supplementalText, source: .qwenASR)
        XCTAssertEqual(request.inputEnvelope.source, .voiceAndImage)
        XCTAssertTrue(request.inputEnvelope.isWellFormed)
        XCTAssertEqual(request.inputEnvelope.imageAttachments.map(\.mediaType), [.jpeg])
        let requestID = UUID()

        var response: AgentResponse?
        for try await event in harness.session.sendEvents(multimodalRequest: request, requestID: requestID) {
            if case .completed(let completed) = event { response = completed }
        }
        XCTAssertEqual(response?.toolCallsCount, 1)

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
        XCTAssertTrue(requests.allSatisfy { request in
            request.messages.allSatisfy { $0.inputEnvelope == nil }
        })
        let userMessages = requests[0].messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 2)
        XCTAssertTrue(userMessages[0].content.contains { content in
            if case .text(let text) = content { return text.contains(supplementalText) }
            return false
        })
        XCTAssertTrue(userMessages[0].content.contains { content in
            if case .image = content { return true }
            return false
        })
        XCTAssertTrue(userMessages[1].content.contains { content in
            if case .text(let text) = content {
                return text.contains("本机临时扫描")
                    && text.contains("不可信")
                    && text.contains(privateOCRText)
            }
            return false
        })

        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
        let storedMessages = try context.fetch(FetchDescriptor<MessageRecord>())
        let storedText = storedMessages.compactMap { String(data: $0.contentData, encoding: .utf8) }.joined()
        XCTAssertTrue(storedText.contains(supplementalText))
        let decodedStoredMessages = storedMessages.compactMap {
            try? JSONDecoder().decode(ModelMessage.self, from: $0.contentData)
        }
        let storedUserEnvelope = try XCTUnwrap(decodedStoredMessages.first(where: { $0.role == .user })?.inputEnvelope)
        XCTAssertEqual(storedUserEnvelope.source, .voiceAndImage)
        XCTAssertEqual(storedUserEnvelope.text?.contains(supplementalText), true)
        XCTAssertEqual(storedUserEnvelope.imageAttachments.count, 1)
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

    func testCompositePhotoMealKeepsSeparateDishesAndUsesLocalCalorieAccounting() async throws {
        let provider = ScriptedTextProvider(
            scripts: [
                [.toolCall(compositeMealCall()), .completed(.toolUse)],
                [.textDelta("照片中的份量区间较宽；清炖牛肉大约有多大份量？"), .completed(.completed)],
                [.toolCall(compositeMealCall()), .completed(.toolUse)],
                [.textDelta("我会保留低可信度估算，请检查待确认草稿。"), .completed(.completed)],
            ],
            capabilities: [.text, .toolCalling, .vision]
        )
        let harness = try makeHarness(provider: provider, grantMealImage: true)

        _ = try await harness.session.send(multimodalRequest: imageRequest())
        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
        _ = try await harness.session.send(
            multimodalRequest: imageRequest().includingSupplementalText("还是不知道，只能按照片估算")
        )

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let meal) = action.payload else {
            return XCTFail("A composite photo meal must stage a meal draft")
        }
        XCTAssertEqual(meal.dishes.map(\.name), ["米饭", "清炖牛肉", "西红柿炒蛋"])
        XCTAssertEqual(
            meal.dishes.map { dish in
                dish.ingredients.filter { $0.name != "烹饪用油" }.map(\.name)
            },
            [["米饭(熟)"], ["牛肉"], ["西红柿", "鸡蛋"]]
        )
        let compositeDish = try XCTUnwrap(meal.dishes.first { $0.name == "西红柿炒蛋" })
        XCTAssertEqual(compositeDish.ingredients.filter { $0.name == "烹饪用油" }.count, 1)
        XCTAssertTrue(meal.dishes.allSatisfy {
            $0.ingredients.filter { $0.name == "烹饪用油" }.count == 1
        })
        XCTAssertTrue(meal.dishes.allSatisfy { $0.algorithmVersion == "meal-estimator-v2" })
        for ingredient in meal.dishes.flatMap(\.ingredients).filter({ $0.name != "烹饪用油" }) {
            XCTAssertGreaterThan(ingredient.amountGrams.low, 0)
            XCTAssertEqual(ingredient.amountGrams.low, ingredient.amountGrams.likely * 0.35, accuracy: 0.001)
            XCTAssertEqual(ingredient.amountGrams.high, ingredient.amountGrams.likely * 1.65, accuracy: 0.001)
            XCTAssertFalse(ingredient.evidence.contains {
                $0.sourceID == "portion:userReportedExact"
            }, "Photo-estimated portions must not become exact measured grams")
            XCTAssertTrue(ingredient.evidence.contains {
                $0.sourceID == "portion:photoWithoutScale" && $0.grade == .weak
            })
        }
        let totalEnergy = try XCTUnwrap(meal.totalNutrients?.energyKcal)
        XCTAssertEqual(totalEnergy.likely, 581.9, accuracy: 0.001)
        XCTAssertEqual(meal.caloriePresentation, .needsClarification(likelyKcal: 582))
        XCTAssertEqual(
            totalEnergy.likely,
            meal.dishes.reduce(0) { $0 + $1.nutrients.energyKcal.likely },
            accuracy: 0.001
        )
        XCTAssertEqual(meal.dishes.flatMap(\.evidence).filter {
            $0.sourceID == "calorie-accounting"
                && $0.sourceVersion == "calorie-accounting-v2"
        }.count, 3)
        XCTAssertTrue(action.payload.summary.contains("约 582 kcal，可信度低"))
        XCTAssertFalse(action.payload.summary.contains("–"))
        let toolResults = Self.toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(toolResults.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertFalse(toolResults.contains { $0.contains("clarification_limit_reached") })
    }

    func testEvidenceOnlyRequestUsesEphemeralProviderMessageWithoutImageConsentOrPersistence() async throws {
        let provider = ScriptedTextProvider(
            scripts: [
                [.toolCall(mealCall()), .completed(.toolUse)],
                [.textDelta("本机线索已整理为待确认草稿。"), .completed(.completed)],
            ],
            capabilities: [.text, .toolCalling]
        )
        let harness = try makeHarness(provider: provider, grantMealImage: false)
        let request = MultimodalModelRequest(
            userText: "请根据本机扫描线索整理待确认餐食，熟米饭150克。",
            mealEvidence: [
                MealEvidence(
                    kind: .nutritionLabel,
                    value: privateOCRText,
                    confidence: 0.92,
                    sourceVersion: "fixture-ocr-v1"
                ),
            ]
        )

        XCTAssertNil(request.image)
        _ = try await harness.session.send(multimodalRequest: request)

        XCTAssertEqual(harness.session.pendingActions.count, 1)
        let requests = provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertFalse(request.messages.contains { message in
                message.content.contains { content in
                    if case .image = content { return true }
                    return false
                }
            })
            XCTAssertTrue(request.messages.contains { message in
                message.role == .user && message.content.contains { content in
                    if case .text(let text) = content {
                        return text.contains("本机临时扫描")
                            && text.contains("不可信")
                            && text.contains(privateOCRText)
                    }
                    return false
                }
            })
        }
        XCTAssertTrue(harness.session.currentMealImageEvidence().isEmpty)

        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        let storedMessages = try context.fetch(FetchDescriptor<MessageRecord>())
        let storedText = storedMessages.compactMap { String(data: $0.contentData, encoding: .utf8) }.joined()
        XCTAssertFalse(storedText.contains(privateOCRText))
        let actionJSON = String(
            data: try harness.session.pendingActions[0].payload.canonicalData(),
            encoding: .utf8
        )!
        XCTAssertFalse(actionJSON.contains(privateOCRText))
        XCTAssertTrue(actionJSON.contains("agent-image:nutritionLabel"))
        let requestRecordValue = try await harness.repository.agentRequest(
            requestID: requests[0].requestID,
            conversationID: harness.conversationID
        )
        let requestRecord = try XCTUnwrap(requestRecordValue)
        XCTAssertTrue(requestRecord.containsTransientImage)
    }

    func testInterruptedEvidenceOnlyRequestRequiresNewRequestToReprovideEvidence() async throws {
        let requestID = UUID()
        let conversationID = UUID()
        let firstProvider = ScriptedTextProvider(
            scripts: [[.completed(.completed)]],
            capabilities: [.text, .toolCalling]
        )
        let firstHarness = try makeHarness(
            provider: firstProvider,
            grantMealImage: false,
            conversationID: conversationID
        )
        let request = MultimodalModelRequest(
            userText: "请用本机线索准备草稿。",
            mealEvidence: [MealEvidence(kind: .nutritionLabel, value: privateOCRText, confidence: 0.9)]
        )

        do {
            _ = try await firstHarness.session.send(multimodalRequest: request, requestID: requestID)
            XCTFail("An empty response should interrupt the evidence-only request")
        } catch {
            XCTAssertEqual(error as? AgentError, .emptyResponse)
        }
        let interruptedValue = try await firstHarness.repository.agentRequest(
            requestID: requestID,
            conversationID: conversationID
        )
        let interrupted = try XCTUnwrap(interruptedValue)
        XCTAssertTrue(interrupted.containsTransientImage)
        XCTAssertEqual(interrupted.state, .interrupted)

        let resumeProvider = ScriptedTextProvider(
            scripts: [[.textDelta("已恢复。"), .completed(.completed)]],
            capabilities: [.text, .toolCalling]
        )
        let resumeHarness = try makeHarness(
            provider: resumeProvider,
            grantMealImage: false,
            conversationID: conversationID,
            existingContainer: firstHarness.container
        )
        try await resumeHarness.session.restore()

        do {
            _ = try await resumeHarness.session.send(userText: "继续", requestID: requestID)
            XCTFail("Transient evidence must not be lost on text-only resume")
        } catch {
            let agentError = error as? AgentError
            XCTAssertEqual(agentError, .transientImageRequired)
            XCTAssertEqual(agentError?.sharedErrorDescriptor.code, .toolArgumentsInvalid)
            XCTAssertEqual(agentError?.sharedErrorDescriptor.reason, .transientImageRequired)
            XCTAssertTrue(agentError?.localizedDescription.contains("重新选择照片") == true)
            XCTAssertFalse(agentError?.sharedErrorDescriptor.diagnosticSafeDetail.contains(privateOCRText) ?? true)
        }
        XCTAssertTrue(resumeProvider.recordedRequests().isEmpty)

        do {
            _ = try await resumeHarness.session.send(multimodalRequest: request, requestID: requestID)
            XCTFail("The single media marker cannot distinguish evidence-only input during resume")
        } catch {
            XCTAssertEqual(error as? AgentError, .transientImageRequired)
        }
        XCTAssertTrue(resumeProvider.recordedRequests().isEmpty)

        let invalidEnvelopeError = AgentError.invalidInputEnvelope
        XCTAssertEqual(invalidEnvelopeError.sharedErrorDescriptor.code, .toolArgumentsInvalid)
        XCTAssertTrue(invalidEnvelopeError.localizedDescription.contains("检查后重新发送"))

        _ = try await resumeHarness.session.send(multimodalRequest: request, requestID: UUID())
        XCTAssertTrue(resumeProvider.recordedRequests().first?.messages.contains { message in
            message.content.contains { content in
                if case .text(let text) = content { return text.contains(privateOCRText) }
                return false
            }
        } == true)
    }

    func testEvidenceOnlyRequestBoundsTransientEvidence() {
        let longText = String(repeating: "local OCR ", count: 30)
        let request = MultimodalModelRequest(
            userText: "请整理本机线索。",
            mealEvidence: (0..<16).map { index in
                MealEvidence(
                    kind: .nutritionLabel,
                    value: "\(index)-\(longText)",
                    confidence: 0.9,
                    sourceVersion: String(repeating: "v", count: 100)
                )
            }
        )

        XCTAssertNil(request.image)
        XCTAssertEqual(request.mealEvidence.count, MultimodalModelRequest.maximumMealEvidenceCount)
        XCTAssertTrue(request.mealEvidence.allSatisfy { $0.value.count <= 160 })
        XCTAssertTrue(request.mealEvidence.allSatisfy { ($0.sourceVersion?.count ?? 0) <= 80 })
    }

    func testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget() async throws {
        let requestID = UUID()
        let conversationID = UUID()
        let deadline = Date().addingTimeInterval(120)
        let firstUsage = ProviderUsage(
            provider: .deepSeek,
            model: "fixture-model",
            capability: .text,
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
                    capability: .text,
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
            existingContainer: initialHarness.container,
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
        let evidenceOnlyReplacement = MultimodalModelRequest(
            userText: request.userText,
            mealEvidence: request.mealEvidence
        )
        do {
            _ = try await resumedHarness.session.send(
                multimodalRequest: evidenceOnlyReplacement,
                requestID: requestID
            )
            XCTFail("Local evidence cannot replace the original transient image on resume")
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

    private static func toolResultContents(in requests: [ModelRequest]) -> [String] {
        var seenToolCallIDs = Set<String>()
        return requests
            .flatMap(\.messages)
            .flatMap(\.content)
            .compactMap { (content: ModelContent) -> String? in
                guard case .toolResult(let callID, let result) = content,
                      seenToolCallIDs.insert(callID).inserted else { return nil }
                return result
            }
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
                                "quantityEvidence": .object([
                                    "kind": .string("photoEstimate"),
                                    "value": .number(150),
                                    "unit": .string("g"),
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

    private func compositeMealCall() -> ToolCall {
        func ingredient(name: String, grams: Double) -> JSONValue {
            .object([
                "name": .string(name),
                "quantityEvidence": .object([
                    "kind": .string("photoEstimate"),
                    "value": .number(grams),
                    "unit": .string("g"),
                    "gramsPerServing": .null,
                ]),
                "preparation": .string("cooked"),
                "massBasis": .string("cooked"),
            ])
        }
        func dish(name: String, cookingMethod: String, ingredients: [(String, Double)]) -> JSONValue {
            .object([
                "dishName": .string(name),
                "cookingMethod": .string(cookingMethod),
                "ingredients": .array(ingredients.map { ingredient(name: $0.0, grams: $0.1) }),
                "lowConfidence": .boolean(false),
            ])
        }
        return ToolCall(
            id: UUID().uuidString,
            name: "log_meal",
            arguments: .object([
                "mealType": .string("lunch"),
                "occurredAt": .null,
                "dishes": .array([
                    dish(name: "米饭", cookingMethod: "steam", ingredients: [("米饭(熟)", 150)]),
                    dish(name: "清炖牛肉", cookingMethod: "stew", ingredients: [("牛肉", 100)]),
                    dish(
                        name: "西红柿炒蛋",
                        cookingMethod: "stirFry",
                        ingredients: [("西红柿", 80), ("鸡蛋", 50)]
                    ),
                ]),
                "note": .null,
            ])
        )
    }

    private func makeHarness(
        provider: ScriptedTextProvider,
        grantMealImage: Bool,
        conversationID: UUID = UUID(),
        existingContainer: ModelContainer? = nil,
        budgetFactory: @escaping @Sendable () -> AgentBudget = { AgentBudget() }
    ) throws -> ImageAgentHarness {
        let container: ModelContainer
        if let existingContainer {
            container = existingContainer
        } else {
            let schema = Schema(versionedSchema: DensosoSchemaV9.self)
            container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
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
            usageLedger: ProviderUsageLedger(repository: governance, pricingDescriptorSource: TestPricingDescriptorCatalog.source),
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
    [
      {"id":2,"name":"米饭(熟)","alias":"熟米饭|白米饭","preparation":"cooked","category":"谷类及制品","edible":100,"energyKcal":116,"proteinG":2.6,"fatG":0.3,"carbohydrateG":25.9,"fiberG":0.3},
      {"id":3,"name":"牛肉","alias":"牛肉|牛肉(熟)","preparation":"cooked","category":"肉类及制品","edible":100,"energyKcal":250,"proteinG":26,"fatG":15,"carbohydrateG":0,"fiberG":0},
      {"id":4,"name":"西红柿","alias":"番茄","preparation":"cooked","category":"蔬菜及制品","edible":100,"energyKcal":18,"proteinG":0.9,"fatG":0.2,"carbohydrateG":3.9,"fiberG":1.2},
      {"id":5,"name":"鸡蛋","alias":"鸡蛋(熟)","preparation":"cooked","category":"蛋类及制品","edible":100,"energyKcal":143,"proteinG":13.1,"fatG":8.9,"carbohydrateG":0.7,"fiberG":0}
    ]
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
