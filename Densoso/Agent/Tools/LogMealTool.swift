import Foundation

struct LogMealTool: ConfirmationRequiredTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "log_meal",
        description: "准备一餐的结构化草稿，不会保存数据。必须展示确认卡并等待用户确认。",
        properties: [
            ("mealType", "string", "进餐类型: breakfast/lunch/dinner/snack", true),
            ("dishes", "string", "菜品数组 JSON；每项含 dishName、cookingMethod、ingredientNames、ingredientAmounts、notedOilG、lowConfidence", true),
            ("datetime", "string", "用餐时间 ISO8601，默认当前", false),
        ]
    ) }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> PendingActionPreparation {
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

        let coefficientTable = CookingCoefficientTable.shared
        var dishes: [MealDishDraft] = []
        for rawDish in rawDishes {
            guard let name = rawDish["dishName"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cookingMethod = rawDish["cookingMethod"] as? String,
                  let ingredientNames = rawDish["ingredientNames"] as? [String],
                  let ingredientAmounts = rawDish["ingredientAmounts"] as? [Double],
                  !ingredientNames.isEmpty, ingredientNames.count == ingredientAmounts.count,
                  ingredientNames.count <= 20 else { throw DraftError.invalidMeal }
            let amountsAreValid = ingredientAmounts.allSatisfy { $0 > 0 && $0 <= 5_000 }
            guard amountsAreValid else { throw DraftError.invalidMeal }
            let oil = rawDish["notedOilG"] as? Double
            guard oil == nil || (oil! >= 0 && oil! <= 500) else { throw DraftError.invalidMeal }

            let method = coefficientTable[cookingMethod]
            let oilGrams = oil ?? method.defaultOilG
            var estimates: [IngredientEstimate] = []
            var calories = Int(round(oilGrams * coefficientTable.oilPerGramKcal))
            var protein = 0.0; var fat = oilGrams; var carbs = 0.0
            for (ingredientName, amount) in zip(ingredientNames, ingredientAmounts) {
                guard let database = context.foodDatabase,
                      let food = try database.search(query: ingredientName, limit: 1).first else { continue }
                let baseCalories = food.adjustedEnergyKcal * amount / 100
                let factor = method.default * coefficientTable.absorptionFactor(for: food.name)
                let adjustedCalories = baseCalories * factor
                estimates.append(IngredientEstimate(foodItemId: food.id, name: food.name, amountG: amount,
                                                    baseCaloriesKcal: baseCalories, oilCoefficient: factor,
                                                    adjustedCaloriesKcal: adjustedCalories))
                calories += Int(round(adjustedCalories))
                protein += food.proteinG * amount / 100; fat += food.fatG * amount / 100; carbs += food.carbohydrateG * amount / 100
            }
            guard !estimates.isEmpty else { throw DraftError.invalidMeal }
            let foundRatio = Double(estimates.count) / Double(ingredientNames.count)
            let isLowConfidence = rawDish["lowConfidence"] as? Bool ?? false
            let confidence = min(foundRatio * 0.6 + (oil == nil ? 0.15 : 0.25) + (cookingMethod == "unknown" ? 0.05 : 0.15), 1)
            dishes.append(MealDishDraft(dishName: name, cookingMethod: cookingMethod, ingredients: estimates, caloriesKcal: calories,
                                        proteinG: protein, fatG: fat, carbsG: carbs, confidence: isLowConfidence ? min(confidence, 0.5) : confidence))
        }
        guard dishes.count == rawDishes.count else { throw DraftError.invalidMeal }
        return PendingActionPreparation(payload: .meal(MealDraft(date: date, mealType: mealType, dishes: dishes)),
                                        idempotencyKey: PendingActionStore.idempotencyKey(for: argumentsJSON, toolName: definition.name))
    }
}
