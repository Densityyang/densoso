import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class LogMealRecipePriorTests: XCTestCase {
    func testLogMealRejectsRecipeIDMissingFromPinnedCatalog() async throws {
        let provider = ScriptedTextProvider(scripts: [])
        let harness = try makeHarness(provider: provider)
        let call = recipeMealCall(recipeID: "unbundled:forged-record")
        let argumentsData = try call.arguments.encodedData()
        let argumentsJSON = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))

        do {
            _ = try await LogMealTool().prepare(argumentsJSON: argumentsJSON, context: harness.session)
            XCTFail("An unbundled recipe identifier must be rejected")
        } catch DraftError.invalidMeal {
            // Expected: identifiers are resolved against the pinned local catalog.
        }
    }

    func testLogMealRejectsBundledRecipeIDWhenDishNameDoesNotMatch() async throws {
        let provider = ScriptedTextProvider(scripts: [])
        let harness = try makeHarness(provider: provider)
        let call = recipeMealCall(
            recipeID: "anduin-howtocook:dishes/aquatic/响油鳝丝.md",
            dishName: "虾炒饭"
        )
        let argumentsData = try call.arguments.encodedData()
        let argumentsJSON = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))

        do {
            _ = try await LogMealTool().prepare(argumentsJSON: argumentsJSON, context: harness.session)
            XCTFail("A bundled recipe ID cannot be reused for a different dish name")
        } catch DraftError.invalidMeal {
            // Expected: the local catalog row must also exactly match the dish name.
        }
    }

    func testExactRecipePriorProvidesUncertainQuantitiesAndPersistedProvenanceWithoutDuplicateOil() async throws {
        let catalog = try RecipePriorCatalog.bundled()
        let recipe = try XCTUnwrap(catalog.exactRecord(
            dishName: "响油鳝丝",
            id: "anduin-howtocook:dishes/aquatic/响油鳝丝.md"
        ))
        let call = recipeMealCall(recipeID: recipe.id)
        let provider = ScriptedTextProvider(
            scripts: [
                [ProviderEvent.toolCall(recipeMealCall(recipeID: recipe.id)), .completed(.toolUse)],
                [.textDelta("这道菜的份量范围较宽；请补充大约吃了多少。"), .completed(.completed)],
                [ProviderEvent.toolCall(call), .completed(.toolUse)],
                [.textDelta("已准备待确认餐食草稿。"), .completed(.completed)],
            ],
            capabilities: [.text, .toolCalling]
        )
        let harness = try makeHarness(provider: provider)

        _ = try await harness.session.send(userText: "我午餐吃了响油鳝丝。")
        XCTAssertTrue(harness.session.pendingActions.isEmpty)

        _ = try await harness.session.send(userText: "还是不知道。")

        let action = try XCTUnwrap(harness.session.pendingActions.first)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a confirmation-required meal draft")
        }
        let dish = try XCTUnwrap(draft.dishes.first)
        XCTAssertEqual(dish.cookingMethod, "stirFry")
        XCTAssertTrue(dish.evidence.contains {
            $0.sourceID == "recipe-prior:\(recipe.sourceID):\(recipe.sourceRecordID)"
                && $0.sourceVersion == recipe.sourceVersion
                && $0.summary.contains(recipe.sourceRecordSHA256)
                && $0.summary.contains(recipe.licenseSPDX)
        })

        let eel = try XCTUnwrap(dish.ingredients.first { $0.name == "鳝丝" })
        XCTAssertEqual(eel.amountGrams.low, 140, accuracy: 0.001)
        XCTAssertEqual(eel.amountGrams.likely, 400, accuracy: 0.001)
        XCTAssertEqual(eel.amountGrams.high, 660, accuracy: 0.001)
        XCTAssertTrue(eel.evidence.contains {
            $0.sourceID?.contains("recipe-prior:\(recipe.id):ingredient:") == true
                && $0.summary.contains("400 g")
        })
        XCTAssertTrue(eel.evidence.contains {
            $0.sourceID == "portion:modelEstimate" && $0.grade == .weak
        })

        XCTAssertEqual(dish.ingredients.filter { $0.name == "猪油" }.count, 1)
        XCTAssertFalse(dish.ingredients.contains { $0.name == "烹饪用油" })
        XCTAssertEqual(
            try ModelContext(harness.container).fetchCount(FetchDescriptor<MealRecord>()),
            0,
            "The meal must remain a draft until the user confirms it."
        )
        XCTAssertTrue(harness.session.foodDatabase === harness.foodDatabase)
    }

    private func recipeMealCall(recipeID: String, dishName: String = "响油鳝丝") -> ToolCall {
        func ingredient(_ name: String) -> JSONValue {
            .object([
                "name": .string(name),
                "quantityEvidence": .object([
                    "kind": .string("unknown"),
                    "value": .null,
                    "unit": .null,
                    "gramsPerServing": .null,
                ]),
                "preparation": .string("unknown"),
                "massBasis": .string("edibleRaw"),
            ])
        }
        return ToolCall(
            id: UUID().uuidString,
            name: "log_meal",
            arguments: .object([
                "mealType": .string("lunch"),
                "occurredAt": .null,
                "dishes": .array([
                    .object([
                        "dishName": .string(dishName),
                        "cookingMethod": .string("stirFry"),
                        "ingredients": .array([ingredient("鳝丝"), ingredient("猪油")]),
                        "lowConfidence": .boolean(false),
                        "recipePriorID": .string(recipeID),
                    ]),
                ]),
                "note": .null,
            ])
        )
    }

    private func makeHarness(provider: ScriptedTextProvider) throws -> RecipePriorHarness {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
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
            usageLedger: ProviderUsageLedger(
                repository: governance,
                pricingDescriptorSource: TestPricingDescriptorCatalog.source
            ),
            registry: ToolRegistry(),
            confirmationCoordinator: confirmation,
            readRepository: repository,
            conversationRepository: repository
        )
        let database = try FoodDatabase(seedJSON: Data(Self.foodSeed.utf8))
        session.foodDatabase = database
        return RecipePriorHarness(container: container, session: session, foodDatabase: database)
    }

    private static let foodSeed = #"""
    [
      {"id":101,"name":"鳝丝","alias":"鳝丝|鳝鱼丝","preparation":"raw","category":"水产","edible":100,"energyKcal":90,"proteinG":18,"fatG":2,"carbohydrateG":0,"fiberG":0},
      {"id":102,"name":"猪油","alias":"猪油","preparation":"raw","category":"油脂类及制品","edible":100,"energyKcal":900,"proteinG":0,"fatG":100,"carbohydrateG":0,"fiberG":0}
    ]
    """#
}

@MainActor
private struct RecipePriorHarness {
    let container: ModelContainer
    let session: AgentSession
    // AgentSession intentionally keeps its food database weakly.
    let foodDatabase: FoodDatabase
}
