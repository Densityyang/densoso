import DensosoDomain
import Foundation

struct LogMealTool: ConfirmationRequiredTool {
    var definition: ToolSchema {
        .strictObject(
            name: "log_meal",
            description: "准备一餐草稿，不会保存；食材候选、生熟和区间必须通过本地解析与确认。",
            effect: .stagesAction,
            properties: [
                "mealType": .string(
                    allowedValues: ["breakfast", "lunch", "dinner", "snack"]
                ),
                "occurredAt": .anyOf([.string(format: "date-time"), .null]),
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
                                        "preparation": .anyOf([
                                            .string(allowedValues: ["raw", "cooked", "unknown"]),
                                            .null,
                                        ]),
                                        "massBasis": .anyOf([
                                            .string(allowedValues: ["asPurchased", "edibleRaw", "cooked"]),
                                            .null,
                                        ]),
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
              arguments.dishes.count <= 20,
              let database = context.foodDatabase else {
            throw DraftError.invalidMeal
        }

        let date: Date
        if let occurredAt = arguments.occurredAt {
            guard let parsed = ISO8601DateFormatter().date(from: occurredAt) else {
                throw DraftError.invalidMeal
            }
            date = parsed
        } else {
            date = Date()
        }

        let resolver = FoodResolver(catalog: try database.catalogEntries())
        let portionEstimator = PortionEstimator()
        let mealEstimator = MealEstimator()
        let oilPriors = CookingOilPriorTable()
        var drafts: [MealDishDraft] = []
        for rawDish in arguments.dishes {
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

            var ingredients: [MealIngredientEstimationInput] = []
            for ingredient in rawDish.ingredients {
                let preparation = FoodPreparation(rawValue: ingredient.preparation ?? "") ?? .unknown
                let confirmedHistory = await context.confirmedFoodIDs(matching: ingredient.name)
                let resolution = resolver.resolve(
                    FoodResolutionQuery(
                        label: ingredient.name,
                        preparation: preparation,
                        sourceQuality: rawDish.lowConfidence ? 0.7 : 1,
                        confirmedHistoryFoodIDs: confirmedHistory
                    )
                )
                guard !resolution.candidates.isEmpty else { throw DraftError.invalidMeal }
                guard resolution.autoPreselect != nil else {
                    throw DraftError.ambiguousFood(
                        name: ingredient.name,
                        candidates: resolution.candidates.map { $0.entry.name }
                    )
                }
                let massBasis = FoodMassBasis(rawValue: ingredient.massBasis ?? "")
                    ?? (preparation == .cooked ? .cooked : .edibleRaw)
                ingredients.append(
                    MealIngredientEstimationInput(
                        label: ingredient.name,
                        resolution: resolution,
                        portion: try portionEstimator.estimate(
                        evidence: [.exactGrams(grams: ingredient.amountGrams)],
                        food: resolution.autoPreselect
                        ),
                        massBasis: massBasis
                    )
                )
            }
            let oilRange = try rawDish.notedOilG.map(EstimateRange.point)
                ?? oilPriors.range(for: rawDish.cookingMethod)
            drafts.append(
                try mealEstimator.estimateDish(
                    MealDishEstimationInput(
                        name: name,
                        cookingMethod: rawDish.cookingMethod,
                        ingredients: ingredients,
                        inferredOilGrams: oilRange
                    )
                )
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
        let preparation: String?
        let massBasis: String?
    }
}
