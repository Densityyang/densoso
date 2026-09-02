import Foundation
import DensosoDomain

struct LogMealTool: ConfirmationRequiredTool {
    var definition: ToolSchema {
        .strictObject(
            name: "log_meal",
            description: "准备一餐的结构化草稿，不会保存数据；烹饪方式只用于推断油量，不能乘食材热量。",
            effect: .stagesAction,
            properties: [
                "mealType": .string(
                    allowedValues: ["breakfast", "lunch", "dinner", "snack"],
                    description: "进餐类型"
                ),
                "occurredAt": .anyOf(
                    [.string(format: "date-time"), .null],
                    description: "用餐时间；null 表示当前"
                ),
                "dishes": .array(
                    items: .object(
                        properties: [
                            "dishName": .string(minimumLength: 1, maximumLength: 120),
                            "cookingMethod": .string(
                                allowedValues: [
                                    "steam", "boil", "coldDress", "stirFry", "braise",
                                    "dryFry", "deepFry", "roast", "stew", "unknown",
                                ]
                            ),
                            "ingredients": .array(
                                items: .object(
                                    properties: [
                                        "name": .string(minimumLength: 1, maximumLength: 120),
                                        "amountGrams": .number(minimum: 0.1, maximum: 5_000),
                                    ],
                                    required: ["name", "amountGrams"],
                                    additionalProperties: false
                                ),
                                minimumItems: 1,
                                maximumItems: 20
                            ),
                            "notedOilG": .anyOf([.number(minimum: 0, maximum: 500), .null]),
                            "lowConfidence": .boolean(),
                        ],
                        required: [
                            "dishName", "cookingMethod", "ingredients", "notedOilG", "lowConfidence",
                        ],
                        additionalProperties: false
                    ),
                    minimumItems: 1,
                    maximumItems: 20
                ),
                "note": .anyOf([.string(maximumLength: 1_000), .null]),
            ],
            required: ["mealType", "occurredAt", "dishes", "note"]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(LogMealArguments.self, from: data),
              Set(["breakfast", "lunch", "dinner", "snack"]).contains(arguments.mealType),
              !arguments.dishes.isEmpty,
              arguments.dishes.count <= 20 else {
            throw DraftError.invalidMeal
        }

        let date: Date
        if let occurredAt = arguments.occurredAt {
            guard let parsed = ISO8601DateFormatter().date(from: occurredAt) else {
                throw DraftError.invalidMeal
            }
            date = parsed
        } else { date = Date() }

        let table = CookingCoefficientTable.shared
        let drafts = try arguments.dishes.map { rawDish -> MealDishDraft in
            let name = rawDish.dishName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !rawDish.ingredients.isEmpty,
                  rawDish.ingredients.count <= 20,
                  rawDish.ingredients.allSatisfy({
                      !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && $0.amountGrams.isFinite
                          && (0.1...5_000).contains($0.amountGrams)
                  }),
                  rawDish.notedOilG == nil
                    || (rawDish.notedOilG!.isFinite && (0...500).contains(rawDish.notedOilG!)) else {
                throw DraftError.invalidMeal
            }
            guard let database = context.foodDatabase else { throw DraftError.invalidMeal }
            let ingredients = try rawDish.ingredients.compactMap { ingredient -> CalorieEstimator.Ingredient? in
                guard let candidate = try database.rankedSearch(query: ingredient.name, limit: 3).first else {
                    return nil
                }
                return CalorieEstimator.Ingredient(
                    item: candidate.item,
                    amountG: ingredient.amountGrams,
                    massBasis: massBasis(for: candidate.item, requestedName: ingredient.name),
                    matchScore: candidate.score
                )
            }
            guard ingredients.count == rawDish.ingredients.count else { throw DraftError.invalidMeal }
            let oil: CalorieEstimator.OilSource = rawDish.notedOilG.map(CalorieEstimator.OilSource.provided)
                ?? .inferred(grams: table[rawDish.cookingMethod].defaultOilG)
            let estimate = CalorieEstimator.estimate(ingredients: ingredients, oil: oil, oilCaloriesPerGram: table.oilPerGramKcal)
            let confidence = rawDish.lowConfidence ? min(estimate.confidence, 0.5) : estimate.confidence
            let domainIngredients = try estimate.ingredientEstimates.map { ingredient in
                MealIngredientDraft(
                    foodID: String(ingredient.foodItemId),
                    name: ingredient.name,
                    amountGrams: try EstimateRange.point(ingredient.amountG),
                    nutrients: NutrientEstimate(
                        energyKcal: try EstimateRange.point(ingredient.adjustedCaloriesKcal)
                    ),
                    evidence: [
                        EvidenceSnapshot(
                            grade: .databaseMatch,
                            sourceID: "food-db:\(ingredient.foodItemId)",
                            sourceVersion: "food-composition-6",
                            summary: ingredient.name,
                            confidence: confidence
                        )
                    ]
                )
            }
            let evidence = estimate.evidence.map {
                EvidenceSnapshot(
                    grade: $0.source == "food_database" ? .databaseMatch : .estimated,
                    sourceID: $0.source,
                    summary: $0.detail,
                    confidence: confidence
                )
            }
            return MealDishDraft(
                name: name,
                cookingMethod: rawDish.cookingMethod,
                portionGrams: try EstimateRange.sum(domainIngredients.map(\.amountGrams)),
                nutrients: NutrientEstimate(
                    energyKcal: try EstimateRange(
                        low: Double(estimate.calories.low),
                        likely: Double(estimate.calories.likely),
                        high: Double(estimate.calories.high)
                    ),
                    proteinGrams: try EstimateRange.point(estimate.proteinG),
                    fatGrams: try EstimateRange.point(estimate.fatG),
                    carbohydrateGrams: try EstimateRange.point(estimate.carbsG)
                ),
                ingredients: domainIngredients,
                evidence: evidence,
                algorithmVersion: "v3"
            )
        }
        return .meal(
            MealDraft(
                occurredAt: date,
                mealType: arguments.mealType,
                dishes: drafts,
                note: arguments.note
            )
        )
    }

    private func massBasis(for item: FoodItem, requestedName: String) -> CalorieEstimator.MassBasis {
        let requested = requestedName.lowercased()
        if item.name.contains("米饭") || requested.contains("熟") { return .cooked }
        return .grossRaw
    }
}

private struct LogMealArguments: Decodable {
    let mealType: String
    let occurredAt: String?
    let dishes: [Dish]
    let note: String?

    struct Dish: Decodable {
        let dishName: String
        let cookingMethod: String
        let ingredients: [Ingredient]
        let notedOilG: Double?
        let lowConfidence: Bool
    }

    struct Ingredient: Decodable {
        let name: String
        let amountGrams: Double
    }
}
