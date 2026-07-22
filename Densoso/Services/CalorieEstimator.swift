import Foundation

/// Pure, explainable calorie estimator. Cooking never multiplies ingredient calories:
/// oils and sauces are represented as explicit ingredients or an explicit oil range.
enum CalorieEstimator {
    enum MassBasis: String, Codable {
        /// Reported mass includes inedible portions (for example, bone-in fish).
        case grossRaw
        /// Reported mass is the edible raw portion.
        case edibleRaw
        /// Reported mass is cooked and must resolve to a cooked food record.
        case cooked
    }

    struct Range: Codable, Equatable {
        let low: Int
        let likely: Int
        let high: Int

        init(low: Double, likely: Double, high: Double) {
            self.low = max(0, Int(low.rounded()))
            self.likely = max(self.low, Int(likely.rounded()))
            self.high = max(self.likely, Int(high.rounded()))
        }
    }

    struct Ingredient {
        let item: FoodItem
        let amountG: Double
        let massBasis: MassBasis
        let matchScore: Double

        var edibleMultiplier: Double { massBasis == .grossRaw ? Double(item.edible) / 100 : 1 }
        var normalizedAmountG: Double { amountG * edibleMultiplier }
    }

    enum OilSource: Equatable {
        case provided(grams: Double)
        case inferred(grams: Double)
    }

    struct Evidence: Equatable {
        let source: String
        let detail: String
    }

    struct Result {
        let calories: Range
        let proteinG: Double
        let fatG: Double
        let carbsG: Double
        let ingredientEstimates: [IngredientEstimate]
        let evidence: [Evidence]
        let confidence: Double
    }

    static func estimate(ingredients: [Ingredient], oil: OilSource, oilCaloriesPerGram: Double = 9) -> Result {
        var likelyCalories = 0.0
        var protein = 0.0
        var fat = 0.0
        var carbs = 0.0
        var estimates: [IngredientEstimate] = []
        var evidence: [Evidence] = []

        for ingredient in ingredients {
            let amount = ingredient.normalizedAmountG
            let calories = ingredient.item.energyKcal * amount / 100
            likelyCalories += calories
            protein += ingredient.item.proteinG * amount / 100
            fat += ingredient.item.fatG * amount / 100
            carbs += ingredient.item.carbohydrateG * amount / 100
            estimates.append(IngredientEstimate(foodItemId: ingredient.item.id, name: ingredient.item.name, amountG: amount,
                                                baseCaloriesKcal: calories, oilCoefficient: 1, adjustedCaloriesKcal: calories))
            evidence.append(Evidence(source: "food_database", detail: "\(ingredient.item.name), \(ingredient.massBasis.rawValue), match \(Int(ingredient.matchScore * 100))%"))
        }

        let oilGrams: Double
        let oilLow: Double
        let oilHigh: Double
        switch oil {
        case .provided(let grams):
            oilGrams = grams; oilLow = grams; oilHigh = grams
            evidence.append(Evidence(source: "user_or_model", detail: "explicit oil \(Int(grams))g"))
        case .inferred(let grams):
            oilGrams = grams; oilLow = max(0, grams * 0.5); oilHigh = grams * 1.5
            evidence.append(Evidence(source: "inference", detail: "oil estimate \(Int(grams))g; range shown"))
        }
        likelyCalories += oilGrams * oilCaloriesPerGram
        fat += oilGrams

        let range: Range
        switch oil {
        case .provided:
            range = Range(low: likelyCalories, likely: likelyCalories, high: likelyCalories)
        case .inferred:
            range = Range(low: likelyCalories - oilGrams * oilCaloriesPerGram + oilLow * oilCaloriesPerGram,
                          likely: likelyCalories,
                          high: likelyCalories - oilGrams * oilCaloriesPerGram + oilHigh * oilCaloriesPerGram)
        }
        let averageMatch = ingredients.isEmpty ? 0 : ingredients.map(\.matchScore).reduce(0, +) / Double(ingredients.count)
        let confidence = min(1, averageMatch * (oilLow == oilHigh ? 1 : 0.8))
        return Result(calories: range, proteinG: protein, fatG: fat, carbsG: carbs, ingredientEstimates: estimates,
                      evidence: evidence, confidence: confidence)
    }
}
