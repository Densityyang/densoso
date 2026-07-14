import Foundation

/// 混合菜品热量引擎 —— densoso 核心差异化
///
/// 流程：
/// 1. 接收 LLM 分解后的 {食材列表, 烹饪方式, 用油量估计}
/// 2. 查本地食材库 → 获取每百克基础热量
/// 3. 应用烹饪方式系数 + 食材吸油修正
/// 4. 组合计算总热量 + 营养素
/// 5. 返回结果 + 置信度
enum DishCalorieEngine {

    // MARK: - 公开类型

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
        let name: String           // 食材名（LLM 还原到标准名）
        let amountG: Double        // 估计用量 (g)
    }

    // MARK: - 主入口

    /// 计算一道菜的热量
    /// - Parameters:
    ///   - rawIngredients: LLM 分解出的食材名+用量
    ///   - cookingMethod: 烹饪方式 (steam/boil/stirFry/braise/dryFry/deepFry/roast/stew/unknown)
    ///   - estimatedOilG: LLM 估计的用油量 (g)，nil 则用默认值
    ///   - dishName: 菜名（用于吸油食材匹配）
    ///   - foodDB: 本地食材库
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
            // 1. 查本地食材库
            let results = try foodDB.search(query: raw.name, limit: 3)
            guard let bestMatch = results.first else {
                // 找不到 → 跳过，降低置信度
                continue
            }

            // 2. 基础热量 = 每百克热量 × 食部% × 用量/100
            let baseKcal = bestMatch.adjustedEnergyKcal * raw.amountG / 100.0

            // 3. 食材吸油修正
            let oilFactor = coefTable.absorptionFactor(for: bestMatch.name)

            // 4. 烹饪方式系数
            let combinedCoefficient = methodCoef.default * oilFactor

            // 5. 调整后热量
            let adjustedKcal = baseKcal * combinedCoefficient

            estimates.append(IngredientEstimate(
                foodItemId: bestMatch.id,
                name: bestMatch.name,
                amountG: raw.amountG,
                baseCaloriesKcal: baseKcal,
                oilCoefficient: combinedCoefficient,
                adjustedCaloriesKcal: adjustedKcal
            ))
            foundCount += 1
        }

        // 油的热量
        let oilCalories = oilGrams * CookingCoefficientTable.shared.oilPerGramKcal

        let totalKcal = Int(round(estimates.map(\.adjustedCaloriesKcal).reduce(0, +) + oilCalories))

        // 营养素估算（基于食材基础值 × 系数）
        let totalProtein = estimates.reduce(0.0) { acc, _ in
            // 简化：蛋白质 = 食材蛋白 × 用量比例
            // 实际应该从 foodDB 查每个食材的 proteinG
            acc + 0  // 需要从 IngredientEstimate 带出蛋白数据
        }
        // TODO: 扩展到完整营养素

        // 置信度
        let confidence = computeConfidence(
            foundCount: foundCount,
            totalCount: rawIngredients.count,
            oilProvided: estimatedOilG != nil,
            cookingMethod: cookingMethod
        )

        // 生成摘要
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
            totalFatG: oilGrams,
            totalCarbsG: 0,  // TODO
            confidence: confidence,
            ingredients: estimates,
            summary: summary
        )
    }

    // MARK: - 置信度

    /// 置信度评分 (0~1)
    private static func computeConfidence(
        foundCount: Int,
        totalCount: Int,
        oilProvided: Bool,
        cookingMethod: String
    ) -> Double {
        let foundRatio = totalCount > 0 ? Double(foundCount) / Double(totalCount) : 0.0
        let oilScore = oilProvided ? 1.0 : 0.5
        let methodScore = cookingMethod == "unknown" ? 0.5 : 1.0

        // 食材找到的权重 0.4, 用油明确 0.4, 烹饪方式明确 0.2
        return foundRatio * 0.4 + oilScore * 0.4 + methodScore * 0.2
    }

    // MARK: - 摘要

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