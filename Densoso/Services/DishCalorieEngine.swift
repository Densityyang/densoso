import Foundation

/// 混合菜品热量引擎 —— densoso 核心差异化
enum DishCalorieEngine {

    struct CalorieResult {
        let totalKcal: Int
        let totalProteinG: Double
        let totalFatG: Double
        let totalCarbsG: Double
        let confidence: Double
        let ingredients: [IngredientEstimate]
        let summary: String
    }

    struct RawIngredient {
        let name: String
        let amountG: Double
    }

    static func estimate(
        rawIngredients: [RawIngredient],
        cookingMethod: String,
        estimatedOilG: Double?,
        dishName: String,
        foodDB: FoodDatabase
    ) throws -> CalorieResult {

        let coefTable = CookingCoefficientTable.shared
        let methodCoef = coefTable[cookingMethod]
        let oilGrams = estimatedOilG ?? methodCoef.defaultOilG

        var estimates: [IngredientEstimate] = []
        var foundCount = 0

        for raw in rawIngredients {
            let results = try foodDB.search(query: raw.name, limit: 3)
            guard let bestMatch = results.first else { continue }

            let baseKcal = bestMatch.adjustedEnergyKcal * raw.amountG / 100.0
            let oilFactor = coefTable.absorptionFactor(for: bestMatch.name)
            let combinedCoef = methodCoef.default * oilFactor
            let adjustedKcal = baseKcal * combinedCoef

            estimates.append(IngredientEstimate(
                foodItemId: bestMatch.id,
                name: bestMatch.name,
                amountG: raw.amountG,
                baseCaloriesKcal: baseKcal,
                oilCoefficient: combinedCoef,
                adjustedCaloriesKcal: adjustedKcal
            ))
            foundCount += 1
        }

        let oilCalories = oilGrams * coefTable.oilPerGramKcal
        let totalKcal = Int(round(estimates.map(\.adjustedCaloriesKcal).reduce(0, +) + oilCalories))

        // 营养素：从每个 IngredientEstimate 带出
        var totalProtein = 0.0
        var totalFat = 0.0
        var totalCarbs = 0.0
        for est in estimates {
            // 通过 foodDB 反查原始食材（这里简化为比例估算）
            // 实际生产版本中应该从 FoodItem 带出完整营养素
            // v1 简化：蛋白/碳水/脂肪按热量比例估算
            let ratio = est.adjustedCaloriesKcal / max(totalKcal, 1)
            totalProtein += est.adjustedCaloriesKcal * 0.15 / 4.0 * ratio // 约15%热量来自蛋白
            totalFat += est.adjustedCaloriesKcal * 0.30 / 9.0 * ratio   // 约30%热量来自脂肪
            totalCarbs += est.adjustedCaloriesKcal * 0.55 / 4.0 * ratio  // 约55%热量来自碳水
        }

        let confidence = computeConfidence(
            foundCount: foundCount,
            totalCount: rawIngredients.count,
            oilProvided: estimatedOilG != nil,
            cookingMethod: cookingMethod
        )

        let summary = generateSummary(
            dishName: dishName,
            totalKcal: totalKcal,
            cookingMethod: methodCoef.label,
            oilG: oilGrams,
            confidence: confidence,
            estimates: estimates
        )

        return CalorieResult(
            totalKcal: totalKcal,
            totalProteinG: totalProtein,
            totalFatG: oilGrams,  // v1 简化为用油量
            totalCarbsG: totalCarbs,
            confidence: confidence,
            ingredients: estimates,
            summary: summary
        )
    }

    private static func computeConfidence(
        foundCount: Int,
        totalCount: Int,
        oilProvided: Bool,
        cookingMethod: String
    ) -> Double {
        let foundRatio = totalCount > 0 ? Double(foundCount) / Double(totalCount) : 0.0
        let oilScore = oilProvided ? 1.0 : 0.5
        let methodScore = cookingMethod == "unknown" ? 0.5 : 1.0
        return foundRatio * 0.4 + oilScore * 0.4 + methodScore * 0.2
    }

    private static func generateSummary(
        dishName: String,
        totalKcal: Int,
        cookingMethod: String,
        oilG: Double,
        confidence: Double,
        estimates: [IngredientEstimate]
    ) -> String {
        let confLabel: String
        switch confidence {
        case ..<0.5: confLabel = "低"
        case 0.5..<0.8: confLabel = "中"
        default: confLabel = "高"
        }
        let ingredientList = estimates.map { "\($0.name) \(Int($0.amountG))g" }.joined(separator: " + ")
        return "「\(dishName)」≈ \(totalKcal) kcal\n" +
               "烹饪方式: \(cookingMethod) | 用油: \(Int(oilG))g\n" +
               "食材: \(ingredientList)\n" +
               "置信度: \(confLabel) (\(String(format: "%.0f", confidence * 100))%)"
    }
}