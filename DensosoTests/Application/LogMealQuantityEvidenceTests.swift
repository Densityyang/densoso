import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class LogMealQuantityEvidenceTests: XCTestCase {
    func testExactGramsUsesCurrentUserTextInsteadOfModelClaim() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("exactGrams", value: 150, unit: "g")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我午餐的米饭186克")

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a pending meal action")
        }
        XCTAssertEqual(draft.dishes.first?.algorithmVersion, "meal-estimator-v2")
        let ingredient = try XCTUnwrap(draft.dishes.first?.ingredients.first)
        XCTAssertEqual(ingredient.amountGrams.low, 186, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.likely, 186, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.high, 186, accuracy: 0.001)
        let portionEvidence = try XCTUnwrap(ingredient.evidence.first {
            $0.sourceID == "portion:userReportedExact"
        })
        XCTAssertEqual(portionEvidence.grade, .strong)
        XCTAssertEqual(portionEvidence.sourceVersion, "portion-estimator-v2")
        XCTAssertTrue(draft.dishes.first?.evidence.contains {
            $0.sourceID == "calorie-accounting" && $0.sourceVersion == "calorie-accounting-v2"
        } == true)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    func testUnverifiedModelGramClaimRequestsClarificationWithoutStaging() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("exactGrams", value: 180, unit: "g")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了一些米饭")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let toolResults = provider.recordedRequests().last?.messages.flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content else { return nil }
            return result
        } ?? []
        XCTAssertTrue(toolResults.contains { $0.contains("clarification_required") })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    func testAnswerAfterOneClarificationStagesWideEstimateWithoutAskingAgain() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(mealCall(ingredientName: "米饭", quantity: quantity("unknown"))),
                .completed(.toolUse),
            ],
            [.textDelta("米饭大约是一小碗还是一大碗？"), .completed(.completed)],
            [
                .toolCall(mealCall(
                    ingredientName: "米饭",
                    quantity: quantity("household", value: 1, unit: "largeBowl")
                )),
                .completed(.toolUse),
            ],
            [.textDelta("已按你补充的份量准备低置信度草稿。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了一些米饭")
        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        _ = try await harness.session.send(userText: "大概一大碗米饭")

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a pending meal action after the user answered")
        }
        let ingredient = try XCTUnwrap(draft.dishes.first?.ingredients.first)
        XCTAssertEqual(ingredient.amountGrams.low, 150, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.likely, 230, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.high, 340, accuracy: 0.001)
        XCTAssertEqual(
            ingredient.evidence.first { $0.sourceID == "portion:householdPrior" }?.grade,
            .weak
        )
        XCTAssertEqual(provider.recordedRequests().count, 4)
        let clarificationResults = provider.recordedRequests().flatMap(\.messages).flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content,
                  result.contains("clarification_required") else { return nil }
            return result
        }
        XCTAssertEqual(clarificationResults.count, 1)
    }

    func testUserStillUncertainAfterClarificationStagesLowConfidenceEstimateWithoutSecondQuestion() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(mealCall(ingredientName: "米饭", quantity: quantity("unknown"))),
                .completed(.toolUse),
            ],
            [.textDelta("米饭大约有多少份量？"), .completed(.completed)],
            [
                .toolCall(mealCall(
                    ingredientName: "米饭",
                    quantity: quantity("unknown", value: 180, unit: "g")
                )),
                .completed(.toolUse),
            ],
            [.textDelta("我会把这份估量标为低可信度，请检查草稿。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了一些米饭")
        _ = try await harness.session.send(userText: "还是不知道")

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a low-confidence pending estimate after the user answered")
        }
        let ingredient = try XCTUnwrap(draft.dishes.first?.ingredients.first)
        XCTAssertEqual(ingredient.amountGrams.low, 63, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.likely, 180, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.high, 297, accuracy: 0.001)
        XCTAssertEqual(
            ingredient.evidence.first { $0.sourceID == "portion:modelEstimate" }?.grade,
            .weak
        )
        let toolResults = provider.recordedRequests().flatMap(\.messages).flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content else { return nil }
            return result
        }
        XCTAssertEqual(toolResults.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertFalse(toolResults.contains { $0.contains("clarification_limit_reached") })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    func testNewUnrelatedFoodDoesNotInheritPreviousMealClarification() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(mealCall(ingredientName: "米饭", quantity: quantity("unknown"))),
                .completed(.toolUse),
            ],
            [.textDelta("米饭大约有多少份量？"), .completed(.completed)],
            [
                .toolCall(mealCall(
                    ingredientName: "牛肉",
                    quantity: quantity("household", value: 1, unit: "palm")
                )),
                .completed(.toolUse),
            ],
            [.textDelta("牛肉这份估算范围较宽，请补充份量。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了一些米饭")
        _ = try await harness.session.send(userText: "今天又吃了些牛肉")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = provider.recordedRequests().last?.messages.flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content else { return nil }
            return result
        } ?? []
        XCTAssertTrue(results.contains { $0.contains("clarification_required") && $0.contains("mealEnergy") })
        XCTAssertFalse(results.contains { $0.contains("clarification_limit_reached") })
    }

    func testVagueNewMealDoesNotCountAsClarificationAnswer() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(mealCall(ingredientName: "米饭", quantity: quantity("unknown"))),
                .completed(.toolUse),
            ],
            [.textDelta("米饭大约有多少份量？"), .completed(.completed)],
            [
                .toolCall(mealCall(
                    ingredientName: "米饭",
                    quantity: quantity("unknown", value: 180, unit: "g")
                )),
                .completed(.toolUse),
            ],
            [.textDelta("我还缺少这餐的份量信息。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了一些米饭")
        _ = try await harness.session.send(userText: "我今天吃了点东西")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let lastResults = provider.recordedRequests().last?.messages.flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content else { return nil }
            return result
        } ?? []
        XCTAssertTrue(lastResults.contains { $0.contains("clarification_required") })
        XCTAssertFalse(lastResults.contains { $0.contains("clarification_limit_reached") })
    }

    func testPackageServingRequiresLocalUserOrLabelGrams() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("packageServing", value: 2, unit: "serving")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了2份米饭，每份40克。")

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a pending meal action")
        }
        let ingredient = try XCTUnwrap(draft.dishes.first?.ingredients.first)
        XCTAssertEqual(ingredient.amountGrams.low, 76, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.likely, 80, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.high, 84, accuracy: 0.001)
        XCTAssertEqual(
            ingredient.evidence.first { $0.sourceID == "portion:packageServing" }?.grade,
            .strong
        )
    }

    func testPackageServingMassIsNotReusedAcrossMixedIngredients() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("packageServing", value: 1, unit: "serving"),
            additionalIngredients: [
                ("牛奶", quantity("packageServing", value: 1, unit: "serving")),
            ]
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "米饭包装每份40克，牛奶每份250克。")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = provider.recordedRequests().last?.messages.flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content else { return nil }
            return result
        } ?? []
        XCTAssertTrue(results.contains { $0.contains("clarification_required") && $0.contains("quantityEvidence") })
    }

    func testUnknownPortionAsksAtMostOneQuestionAndNeverStagesMeal() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(mealCall(ingredientName: "米饭", quantity: quantity("unknown"))),
                .toolCall(mealCall(
                    ingredientName: "米饭",
                    quantity: quantity("household", value: 1, unit: "bowl")
                )),
                .completed(.toolUse),
            ],
            [.textDelta("请补充份量后我再估算。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        let response = try await harness.session.send(userText: "我吃了一些米饭")

        XCTAssertEqual(response.toolCallsCount, 2)
        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
        let requests = provider.recordedRequests()
        let toolResults = try XCTUnwrap(requests.last).messages.flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content else { return nil }
            return result
        }
        XCTAssertEqual(toolResults.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertEqual(toolResults.filter { $0.contains("clarification_limit_reached") }.count, 1)
        XCTAssertTrue(toolResults.contains { $0.contains("maximumQuestions") && $0.contains("1") })
    }

    func testUnknownFoodIdentityDoesNotReceiveInventedCalories() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "神秘食物",
            quantity: quantity("household", value: 1, unit: "bowl")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了一碗神秘食物")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = provider.recordedRequests().last?.messages.flatMap(\.content).compactMap { content in
            guard case .toolResult(_, let result) = content else { return nil }
            return result
        } ?? []
        XCTAssertTrue(results.contains { $0.contains("clarification_required") && $0.contains("foodIdentity") })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    private func quantity(
        _ kind: String,
        value: Double? = nil,
        unit: String? = nil,
        gramsPerServing: Double? = nil
    ) -> JSONValue {
        .object([
            "kind": .string(kind),
            "value": value.map(JSONValue.number) ?? .null,
            "unit": unit.map(JSONValue.string) ?? .null,
            "gramsPerServing": gramsPerServing.map(JSONValue.number) ?? .null,
        ])
    }

    private func mealCall(
        ingredientName: String,
        quantity: JSONValue,
        additionalIngredients: [(String, JSONValue)] = []
    ) -> ToolCall {
        let ingredientArguments = [(ingredientName, quantity)] + additionalIngredients
        return ToolCall(
            id: UUID().uuidString,
            name: "log_meal",
            arguments: .object([
                "mealType": .string("lunch"),
                "occurredAt": .null,
                "dishes": .array([
                    .object([
                        "dishName": .string(ingredientName),
                        "cookingMethod": .string("unknown"),
                        "ingredients": .array(ingredientArguments.map { name, evidence in
                            .object([
                                "name": .string(name),
                                "quantityEvidence": evidence,
                                "preparation": .string("cooked"),
                                "massBasis": .string("cooked"),
                            ])
                        }),
                        "lowConfidence": .boolean(false),
                    ]),
                ]),
                "note": .null,
            ])
        )
    }

    private func provider(calls: [ToolCall]) -> ScriptedTextProvider {
        ScriptedTextProvider(scripts: [
            calls.map(ProviderEvent.toolCall) + [.completed(.toolUse)],
            [.textDelta("已准备待确认餐食草稿。"), .completed(.completed)],
        ])
    }

    private func makeHarness(provider: ScriptedTextProvider) throws -> MealQuantityHarness {
        let schema = Schema(versionedSchema: DensosoSchemaV5.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        let governance = InMemoryProviderGovernanceRepository(granted: [(.deepSeek, .healthText)])
        let preferences = IntelligencePreferences()
        preferences.mode = .cloudDeepSeek
        let confirmation = ConfirmationCoordinator(
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
            confirmationCoordinator: confirmation,
            readRepository: repository,
            conversationRepository: repository
        )
        let database = try FoodDatabase(seedJSON: Data(Self.foodSeed.utf8))
        session.foodDatabase = database
        return MealQuantityHarness(container: container, session: session)
    }

    private static let foodSeed = #"[
      {"id":2,"name":"米饭(熟)","alias":"米饭|熟米饭|白米饭","preparation":"cooked","category":"谷类及制品","edible":100,"energyKcal":116,"proteinG":2.6,"fatG":0.3,"carbohydrateG":25.9,"fiberG":0.3},
      {"id":3,"name":"牛肉","alias":"牛肉|牛肉(熟)","preparation":"cooked","category":"肉类及制品","edible":100,"energyKcal":250,"proteinG":26,"fatG":15,"carbohydrateG":0,"fiberG":0}
    ]"#
}

@MainActor
private struct MealQuantityHarness {
    let container: ModelContainer
    let session: AgentSession
}
