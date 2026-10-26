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
        let toolResults = toolResultContents(in: provider.recordedRequests().last)
        XCTAssertTrue(toolResults.contains { $0.contains("clarification_required") })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    func testPhotoEstimateWithoutCurrentImageRequestsPortionEvidence() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("photoEstimate", value: 180, unit: "g")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我吃了一些米饭")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let toolResults = toolResultContents(in: provider.recordedRequests().last)
        XCTAssertTrue(toolResults.contains {
            $0.contains("clarification_required") && $0.contains("quantityEvidence")
        })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    func testPhotoEstimateWithWideMealRangeAsksOnceBeforeStaging() async throws {
        let provider = ScriptedTextProvider(
            scripts: [
                [
                    .toolCall(mealCall(
                        ingredientName: "米饭",
                        quantity: quantity("photoEstimate", value: 180, unit: "g")
                    )),
                    .completed(.toolUse),
                ],
                [.textDelta("照片估算范围较宽；米饭大约有多少份量？"), .completed(.completed)],
                [
                    .toolCall(mealCall(
                        ingredientName: "米饭",
                        quantity: quantity("photoEstimate", value: 180, unit: "g")
                    )),
                    .completed(.toolUse),
                ],
                [.textDelta("我会保留低可信度估算，请检查待确认草稿。"), .completed(.completed)],
            ],
            capabilities: [.text, .toolCalling, .vision]
        )
        let harness = try makeHarness(provider: provider, grantMealImage: true)

        _ = try await harness.session.send(multimodalRequest: photoRequest())

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
        let firstTurnResults = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(firstTurnResults.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertTrue(firstTurnResults.contains {
            $0.contains("clarification_required") && $0.contains("mealEnergy")
        })

        _ = try await harness.session.send(
            multimodalRequest: try photoRequest().includingSupplementalText("还是不知道，只能按照片估算")
        )

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a low-confidence meal draft after the one clarification")
        }
        let ingredient = try XCTUnwrap(draft.dishes.first?.ingredients.first)
        XCTAssertEqual(ingredient.amountGrams.low, 63, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.likely, 180, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.high, 297, accuracy: 0.001)
        XCTAssertEqual(
            ingredient.evidence.first { $0.sourceID == "portion:photoWithoutScale" }?.grade,
            .weak
        )
        let allToolResults = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(allToolResults.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertFalse(allToolResults.contains { $0.contains("clarification_limit_reached") })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    func testExplicitCurrentTurnConsumedFractionScalesMealIntakeAndEvidence() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("packageServing", value: 1, unit: "serving")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "米饭包装每份100克。我吃了一半。")

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a meal draft with the reported consumed fraction")
        }
        let evidence = try XCTUnwrap(draft.consumedFractionEvidence)
        XCTAssertEqual(evidence.fraction, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(evidence.source, .currentUserReport)
        XCTAssertEqual(evidence.parserVersion, ConsumedFractionEvidence.currentParserVersion)
        let dish = try XCTUnwrap(draft.dishes.first)
        let ingredient = try XCTUnwrap(dish.ingredients.first)
        XCTAssertEqual(ingredient.amountGrams.low, 47.5, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.likely, 50, accuracy: 0.001)
        XCTAssertEqual(ingredient.amountGrams.high, 52.5, accuracy: 0.001)
        XCTAssertEqual(draft.totalNutrients?.energyKcal.likely ?? -1, 58, accuracy: 0.001)
        XCTAssertTrue(dish.evidence.contains {
            $0.sourceID == "meal-consumed-fraction:user-report"
                && $0.sourceVersion == ConsumedFractionEvidence.currentParserVersion
                && $0.grade == .userReported
        })
    }

    func testExplicitWholeMealFractionScalesEveryDish() async throws {
        let provider = provider(calls: [multiDishRiceBeefMealCall()])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "米饭包装每份100克。牛肉包装每份100克。这顿饭我吃了一半。"
        )

        let scaledAction = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let scaledDraft) = scaledAction.payload else {
            return XCTFail("Expected a globally scaled multi-dish meal")
        }
        XCTAssertEqual(
            try XCTUnwrap(scaledDraft.consumedFractionEvidence).fraction,
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(scaledDraft.dishes.compactMap { $0.ingredients.first?.amountGrams.likely }, [50, 50])
        XCTAssertEqual(scaledDraft.totalNutrients?.energyKcal.likely ?? -1, 183, accuracy: 0.001)
    }

    func testFractionScopedToOneOfSeveralFoodsRequiresClarificationWithoutStaging() async throws {
        let provider = provider(calls: [multiDishRiceBeefMealCall()])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "米饭包装每份100克。牛肉包装每份100克。我吃了一半牛肉。"
        )

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertTrue(results.contains {
            $0.contains("clarification_required")
                && $0.contains("consumedFraction")
                && $0.contains("整餐实际吃下的份量")
        })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
    }

    func testUnscopedConsumedFractionRequiresClarificationWithoutStaging() async throws {
        let provider = provider(calls: [multiDishRiceBeefMealCall()])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "米饭包装每份100克。牛肉包装每份100克。我吃了一半。"
        )

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertTrue(results.contains {
            $0.contains("clarification_required") && $0.contains("consumedFraction")
        })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
    }

    func testApproximateConsumedFractionRequiresClarificationWithoutStaging() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("packageServing", value: 1, unit: "serving")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "米饭包装每份100克。我大概吃了一半。")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertTrue(results.contains {
            $0.contains("clarification_required") && $0.contains("consumedFraction")
        })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
    }

    func testNegatedConsumedFractionRequiresClarificationWithoutScaling() async throws {
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: quantity("packageServing", value: 1, unit: "serving")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "米饭包装每份100克。我没吃一半。")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertTrue(results.contains {
            $0.contains("clarification_required") && $0.contains("consumedFraction")
        })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
    }

    func testUnknownAnswerToConsumedFractionClarificationNeverStagesFullMeal() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("请说明比例是指整餐还是其中一道菜。"), .completed(.completed)],
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("没有足够信息按全份计入。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "米饭包装每份100克。牛肉包装每份100克。我吃了一半牛肉。"
        )
        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        try await harness.session.restore()

        _ = try await harness.session.send(
            userText: "还是不知道比例。米饭包装每份100克。牛肉包装每份100克。"
        )

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertEqual(results.filter { $0.contains("clarification_limit_reached") }.count, 1)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
    }

    func testWholeMealFractionAnswerAfterClarificationAndRestoreScalesEveryDish() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("请说明比例是指整餐还是其中一道菜。"), .completed(.completed)],
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("已按整餐一半准备待确认草稿。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "米饭包装每份100克。牛肉包装每份100克。我吃了一半。"
        )
        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        try await harness.session.restore()

        _ = try await harness.session.send(
            userText: "这顿饭一半。米饭包装每份100克。牛肉包装每份100克。"
        )

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("An explicit whole-meal answer should resolve the prior clarification")
        }
        XCTAssertEqual(try XCTUnwrap(draft.consumedFractionEvidence).fraction, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(draft.dishes.compactMap { $0.ingredients.first?.amountGrams.likely }, [50, 50])
        XCTAssertEqual(draft.totalNutrients?.energyKcal.likely ?? -1, 183, accuracy: 0.001)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertFalse(results.contains { $0.contains("clarification_limit_reached") })
    }

    func testSingleDishFractionAnswerAfterClarificationDoesNotStageWholeMeal() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("请说明比例是指整餐还是其中一道菜。"), .completed(.completed)],
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("范围仍不明确，因此没有暂存整餐。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "米饭包装每份100克。牛肉包装每份100克。我吃了一半。"
        )
        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        try await harness.session.restore()

        _ = try await harness.session.send(
            userText: "牛肉一半。米饭包装每份100克。牛肉包装每份100克。"
        )

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertEqual(results.filter { $0.contains("clarification_limit_reached") }.count, 1)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
    }

    func testSingleDishOnlyAnswerAfterClarificationDoesNotStageWholeMeal() async throws {
        let provider = ScriptedTextProvider(scripts: [
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("请说明比例是指整餐还是其中一道菜。"), .completed(.completed)],
            [
                .toolCall(multiDishRiceBeefMealCall()),
                .completed(.toolUse),
            ],
            [.textDelta("只确认了菜品范围，无法按全份暂存。"), .completed(.completed)],
        ])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "米饭包装每份100克。牛肉包装每份100克。我吃了一半。"
        )
        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        try await harness.session.restore()

        _ = try await harness.session.send(
            userText: "牛肉。米饭包装每份100克。牛肉包装每份100克。"
        )

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertEqual(results.filter { $0.contains("clarification_limit_reached") }.count, 1)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
    }

    func testRepeatedIngredientAcrossDishesRequiresClarificationInsteadOfDeduplicating() async throws {
        let provider = provider(calls: [repeatedRiceMealCall(
            quantity: quantity("household", value: 1, unit: "bowl")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "午餐有一碗白米饭和一份牛肉盖饭")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertTrue(results.contains {
            $0.contains("mealEnergy") && $0.contains("避免重复计入")
        })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
    }

    func testExplicitlySeparateRepeatedIngredientPortionsAreBothCounted() async throws {
        let provider = provider(calls: [repeatedRiceMealCall(
            quantity: quantity("packageServing", value: 1, unit: "serving")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(
            userText: "午餐两道菜分别各有一份米饭，每份40克"
        )

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Explicitly separate portions should both remain in the draft")
        }
        XCTAssertEqual(draft.dishes.count, 2)
        XCTAssertEqual(draft.dishes.compactMap { $0.ingredients.first?.name }, ["米饭(熟)", "米饭(熟)"])
        XCTAssertEqual(draft.totalNutrients?.energyKcal.likely ?? -1, 92.8, accuracy: 0.001)
        XCTAssertTrue(toolResultContents(in: provider.recordedRequests())
            .allSatisfy { !$0.contains("clarification_required") })
    }

    func testRepeatedIngredientOccurrencesWithinOneDishAreNotGloballyDeduplicated() async throws {
        let packageServing = quantity("packageServing", value: 1, unit: "serving")
        let provider = provider(calls: [mealCall(
            ingredientName: "米饭",
            quantity: packageServing,
            additionalIngredients: [("米饭", packageServing)]
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "米饭包装每份40克，这道菜用了两份米饭")

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Repeated occurrences in one dish should remain in the estimate")
        }
        let ingredients = try XCTUnwrap(draft.dishes.first?.ingredients)
        XCTAssertEqual(ingredients.count, 2)
        XCTAssertEqual(ingredients.map(\.amountGrams.likely), [40, 40])
        XCTAssertEqual(draft.totalNutrients?.energyKcal.likely ?? -1, 92.8, accuracy: 0.001)
    }

    func testUserConfirmsRepeatedIngredientIsOneSharedPortionAndRequiresDraftCorrection() async throws {
        let provider = provider(calls: [repeatedRiceMealCall(
            quantity: quantity("household", value: 1, unit: "bowl")
        )])
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "两道菜里的米饭是同一份，只能算一次")

        XCTAssertTrue(harness.session.pendingActions.isEmpty)
        let results = toolResultContents(in: provider.recordedRequests())
        XCTAssertEqual(results.filter { $0.contains("clarification_required") }.count, 1)
        XCTAssertTrue(results.contains {
            $0.contains("只保留一次") && $0.contains("合并后的份量")
        })
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try ModelContext(harness.container).fetchCount(FetchDescriptor<PendingActionRecord>()), 0)
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
        let clarificationResults = toolResultContents(in: provider.recordedRequests())
            .filter { $0.contains("clarification_required") }
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
        let toolResults = toolResultContents(in: provider.recordedRequests())
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
        let results = toolResultContents(in: provider.recordedRequests().last)
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
        let lastResults = toolResultContents(in: provider.recordedRequests().last)
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
        let results = toolResultContents(in: provider.recordedRequests().last)
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
        let toolResults = toolResultContents(in: requests.last)
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
        let results = toolResultContents(in: provider.recordedRequests().last)
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

    private func photoRequest() throws -> MultimodalModelRequest {
        try MultimodalModelRequest(
            userText: "请根据照片准备餐食草稿。",
            imageJPEG: Data([0xFF, 0xD8, 0xFF]),
            mealEvidence: []
        )
    }

    private func toolResultContents(in request: ModelRequest?) -> [String] {
        guard let request else { return [] }
        return toolResultContents(in: [request])
    }

    private func toolResultContents(in requests: [ModelRequest]) -> [String] {
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

    private func repeatedRiceMealCall(quantity: JSONValue) -> ToolCall {
        func dish(name: String) -> JSONValue {
            .object([
                "dishName": .string(name),
                "cookingMethod": .string("unknown"),
                "ingredients": .array([
                    .object([
                        "name": .string("米饭"),
                        "quantityEvidence": quantity,
                        "preparation": .string("cooked"),
                        "massBasis": .string("cooked"),
                    ]),
                ]),
                "lowConfidence": .boolean(false),
            ])
        }
        return ToolCall(
            id: UUID().uuidString,
            name: "log_meal",
            arguments: .object([
                "mealType": .string("lunch"),
                "occurredAt": .null,
                "dishes": .array([dish(name: "白米饭"), dish(name: "牛肉盖饭")]),
                "note": .null,
            ])
        )
    }

    private func multiDishRiceBeefMealCall() -> ToolCall {
        func dish(name: String, method: String = "unknown") -> JSONValue {
            .object([
                "dishName": .string(name),
                "cookingMethod": .string(method),
                "ingredients": .array([
                    .object([
                        "name": .string(name),
                        "quantityEvidence": quantity("packageServing", value: 1, unit: "serving"),
                        "preparation": .string("cooked"),
                        "massBasis": .string("cooked"),
                    ]),
                ]),
                "lowConfidence": .boolean(false),
            ])
        }
        return ToolCall(
            id: UUID().uuidString,
            name: "log_meal",
            arguments: .object([
                "mealType": .string("lunch"),
                "occurredAt": .null,
                "dishes": .array([dish(name: "米饭"), dish(name: "牛肉")]),
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

    private func makeHarness(
        provider: ScriptedTextProvider,
        grantMealImage: Bool = false
    ) throws -> MealQuantityHarness {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let repository = SwiftDataAgentRepository(modelContainer: container)
        var grants: [(ProviderID, ProviderDataClass)] = [(.deepSeek, .healthText)]
        if grantMealImage { grants.append((.deepSeek, .mealImage)) }
        let governance = InMemoryProviderGovernanceRepository(granted: grants)
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
            usageLedger: ProviderUsageLedger(repository: governance, pricingDescriptorSource: TestPricingDescriptorCatalog.source),
            registry: ToolRegistry(),
            confirmationCoordinator: confirmation,
            readRepository: repository,
            conversationRepository: repository
        )
        let database = try FoodDatabase(seedJSON: Data(Self.foodSeed.utf8))
        session.foodDatabase = database
        return MealQuantityHarness(container: container, session: session, foodDatabase: database)
    }

    private static let foodSeed = #"""
    [
      {"id":2,"name":"米饭(熟)","alias":"米饭|熟米饭|白米饭","preparation":"cooked","category":"谷类及制品","edible":100,"energyKcal":116,"proteinG":2.6,"fatG":0.3,"carbohydrateG":25.9,"fiberG":0.3},
      {"id":3,"name":"牛肉","alias":"牛肉|牛肉(熟)","preparation":"cooked","category":"肉类及制品","edible":100,"energyKcal":250,"proteinG":26,"fatG":15,"carbohydrateG":0,"fiberG":0}
    ]
    """#
}

@MainActor
private struct MealQuantityHarness {
    let container: ModelContainer
    let session: AgentSession
    let foodDatabase: FoodDatabase
}
