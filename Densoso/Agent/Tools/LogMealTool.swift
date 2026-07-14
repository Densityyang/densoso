import Foundation
import SwiftData

struct LogMealTool: AgentTool {
    var definition: DeepSeekClient.ToolDef { .make(
        name: "log_meal",
        description: """
        记录一餐。对每道菜必须拆解为食材+烹饪方式+份量估计。
        如果菜名或份量模糊，设置 lowConfidence=true，系统会触发确认。
        注意：中餐烹饪方式与用油量是热量估算的关键变量。
        """,
        properties: [
            ("mealType", "string", "进餐类型: breakfast/lunch/dinner/snack", true),
            ("dishes", "string", "菜品数组 JSON", true),
            ("datetime", "string", "用餐时间 ISO8601，默认当前", false),
        ]
    )}

    func execute(argumentsJSON: String, context: AgentSession, modelContext: ModelContext) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"error": "参数解析失败"}"#
        }

        let mealType = json["mealType"] as? String ?? "lunch"
        let dishesJSON = json["dishes"] as? String ?? "[]"

        guard let dishesData = dishesJSON.data(using: .utf8),
              let dishes = try? JSONSerialization.jsonObject(with: dishesData) as? [[String: Any]] else {
            return #"{"error": "dishes 字段格式错误"}"#
        }

        let foodDB = context.foodDatabase
        var createdDishes: [DishEntry] = []
        var totalKcal = 0
        var totalProtein = 0.0
        var totalFat = 0.0
        var totalCarbs = 0.0
        var anyLowConfidence = false

        for dish in dishes {
            let dishName = dish["dishName"] as? String ?? "未知菜品"
            let cookingMethod = dish["cookingMethod"] as? String ?? "unknown"
            let ingredientNames = dish["ingredientNames"] as? [String] ?? []
            let ingredientAmounts = dish["ingredientAmounts"] as? [Double] ?? []
            let notedOilG = dish["notedOilG"] as? Double
            let lowConfidence = dish["lowConfidence"] as? Bool ?? false
            if lowConfidence { anyLowConfidence = true }

            var estimates: [IngredientEstimate] = []
            var dishKcal = 0; var dishProtein = 0.0; var dishFat = 0.0; var dishCarbs = 0.0
            let coefTable = CookingCoefficientTable.shared
            let methodCoef = coefTable[cookingMethod]
            let oilGrams = notedOilG ?? methodCoef.defaultOilG

            for (idx, name) in ingredientNames.enumerated() {
                let amountG = idx < ingredientAmounts.count ? ingredientAmounts[idx] : 100.0
                if let db = foodDB, let match = try? db.search(query: name, limit: 1).first {
                    let baseKcal = match.adjustedEnergyKcal * amountG / 100.0
                    let oilFactor = coefTable.absorptionFactor(for: match.name)
                    let combinedCoef = methodCoef.default * oilFactor
                    let adjustedKcal = baseKcal * combinedCoef
                    estimates.append(IngredientEstimate(
                        foodItemId: match.id, name: match.name, amountG: amountG,
                        baseCaloriesKcal: baseKcal, oilCoefficient: combinedCoef, adjustedCaloriesKcal: adjustedKcal
                    ))
                    dishKcal += Int(round(adjustedKcal))
                    dishProtein += match.proteinG * amountG / 100.0
                    dishFat += match.fatG * amountG / 100.0
                    dishCarbs += match.carbohydrateG * amountG / 100.0
                }
            }
            let oilKcal = Int(round(oilGrams * coefTable.oilPerGramKcal))
            dishKcal += oilKcal; dishFat += oilGrams

            let foundRatio = ingredientNames.isEmpty ? 0.0 : Double(estimates.count) / Double(ingredientNames.count)
            let conf = foundRatio * 0.4 + (notedOilG != nil ? 0.4 : 0.2) + (cookingMethod != "unknown" ? 0.2 : 0.1)

            let entry = DishEntry(
                dishName: dishName, cookingMethod: cookingMethod,
                estimatedCaloriesKcal: dishKcal, estimatedProteinG: dishProtein,
                estimatedFatG: dishFat, estimatedCarbsG: dishCarbs,
                confidenceScore: min(conf, 1.0)
            )
            entry.setIngredients(estimates)
            createdDishes.append(entry)
            totalKcal += dishKcal; totalProtein += dishProtein; totalFat += dishFat; totalCarbs += dishCarbs
        }

        let meal = MealRecord(
            date: Date(), mealType: mealType, totalCaloriesKcal: totalKcal,
            proteinG: totalProtein, fatG: totalFat, carbsG: totalCarbs,
            confidence: anyLowConfidence ? "medium" : "high"
        )
        meal.dishes = createdDishes
        modelContext.insert(meal)
        try modelContext.save()

        // 触发 DailyMetrics 重算并保存
        recomputeDailyMetrics(modelContext: modelContext)

        let dishesSummary = createdDishes.map { "\($0.dishName): \($0.estimatedCaloriesKcal) kcal" }.joined(separator: "; ")
        let result: [String: Any] = [
            "mealId": meal.id.uuidString, "mealType": mealType, "totalCalories": totalKcal,
            "totalProtein": totalProtein, "totalFat": totalFat, "totalCarbs": totalCarbs,
            "dishes": dishesSummary, "needsConfirmation": anyLowConfidence,
        ]
        let resultData = try JSONSerialization.data(withJSONObject: result)
        return String(data: resultData, encoding: .utf8) ?? "{}"
    }

    private func recomputeDailyMetrics(modelContext: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!

        let profile = (try? modelContext.fetch(FetchDescriptor<UserProfile>()).first) ?? UserProfile()

        let mealPred = #Predicate<MealRecord> { m in
            m.date >= today && m.date < tomorrow
        }
        let meals = (try? modelContext.fetch(FetchDescriptor<MealRecord>(predicate: mealPred))) ?? []

        let workoutPred = #Predicate<WorkoutRecord> { w in
            w.date >= today && w.date < tomorrow
        }
        let workouts = (try? modelContext.fetch(FetchDescriptor<WorkoutRecord>(predicate: workoutPred))) ?? []

        let metrics = CaloricEngine.computeDailyMetrics(date: today, meals: meals, workouts: workouts, userProfile: profile)

        let existingPred = #Predicate<DailyMetrics> { $0.date == today }
        if let existing = (try? modelContext.fetch(FetchDescriptor<DailyMetrics>(predicate: existingPred)))?.first {
            modelContext.delete(existing)
        }
        modelContext.insert(metrics)
        try? modelContext.save()
    }
}
