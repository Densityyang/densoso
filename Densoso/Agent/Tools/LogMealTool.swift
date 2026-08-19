import Foundation
import DensosoDomain

struct LogMealTool: ConfirmationRequiredTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "log_meal",
        description: "准备一餐的结构化草稿，不会保存数据。dishes 是数组 JSON；烹饪方式只用于推断油量，绝不能乘食材热量。",
        properties: [
            ("mealType", "string", "进餐类型: breakfast/lunch/dinner/snack", true),
            ("dishes", "string", "菜品数组 JSON；每项含 dishName、cookingMethod、ingredientNames、ingredientAmounts、notedOilG、lowConfidence", true),
            ("datetime", "string", "用餐时间 ISO8601，默认当前", false),
        ]
    ) }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mealType = json["mealType"] as? String,
              Set(["breakfast", "lunch", "dinner", "snack"]).contains(mealType),
              let dishesJSON = json["dishes"] as? String,
              let dishesData = dishesJSON.data(using: .utf8),
              let rawDishes = try JSONSerialization.jsonObject(with: dishesData) as? [[String: Any]],
              !rawDishes.isEmpty, rawDishes.count <= 20 else { throw DraftError.invalidMeal }

        let date: Date
        if let datetime = json["datetime"] as? String {
            guard let parsed = ISO8601DateFormatter().date(from: datetime) else { throw DraftError.invalidMeal }
            date = parsed
        } else { date = Date() }

        let table = CookingCoefficientTable.shared
        let drafts = try rawDishes.map { rawDish -> MealDishDraft in
            guard let name = rawDish["dishName"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cookingMethod = rawDish["cookingMethod"] as? String,
                  let ingredientNames = rawDish["ingredientNames"] as? [String],
                  let ingredientAmounts = rawDish["ingredientAmounts"] as? [Double],
                  !ingredientNames.isEmpty, ingredientNames.count == ingredientAmounts.count,
                  ingredientNames.count <= 20,
                  ingredientAmounts.allSatisfy({ $0 > 0 && $0 <= 5_000 }) else { throw DraftError.invalidMeal }

            let explicitOil = rawDish["notedOilG"] as? Double
            guard explicitOil == nil || (explicitOil! >= 0 && explicitOil! <= 500) else { throw DraftError.invalidMeal }
            guard let database = context.foodDatabase else { throw DraftError.invalidMeal }
            let ingredients = try zip(ingredientNames, ingredientAmounts).compactMap { pair -> CalorieEstimator.Ingredient? in
                guard let candidate = try database.rankedSearch(query: pair.0, limit: 3).first else { return nil }
                return CalorieEstimator.Ingredient(item: candidate.item, amountG: pair.1,
                                                   massBasis: massBasis(for: candidate.item, requestedName: pair.0), matchScore: candidate.score)
            }
            guard ingredients.count == ingredientNames.count else { throw DraftError.invalidMeal }
            let oil: CalorieEstimator.OilSource = explicitOil.map(CalorieEstimator.OilSource.provided)
                ?? .inferred(grams: table[cookingMethod].defaultOilG)
            let estimate = CalorieEstimator.estimate(ingredients: ingredients, oil: oil, oilCaloriesPerGram: table.oilPerGramKcal)
            let lowConfidence = rawDish["lowConfidence"] as? Bool ?? false
            let confidence = lowConfidence ? min(estimate.confidence, 0.5) : estimate.confidence
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
                cookingMethod: cookingMethod,
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
        return .meal(MealDraft(occurredAt: date, mealType: mealType, dishes: drafts))
    }

    private func massBasis(for item: FoodItem, requestedName: String) -> CalorieEstimator.MassBasis {
        let requested = requestedName.lowercased()
        if item.name.contains("米饭") || requested.contains("熟") { return .cooked }
        return .grossRaw
    }
}
