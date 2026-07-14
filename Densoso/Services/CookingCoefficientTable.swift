import Foundation

/// 从 cooking_coefficients.json 加载的静态系数表
/// v1: 启动时加载，失败则返回安全默认值（不打断 App）
final class CookingCoefficientTable {
    nonisolated(unsafe) static let shared = CookingCoefficientTable()

    let coefficients: [MethodCoefficient]
    let ingredientAbsorption: [IngredientAbsorption]
    let oilPerGramKcal: Double

    private init() {
        if let url = Bundle.main.url(forResource: "cooking_coefficients", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode(RawTable.self, from: data) {
            self.coefficients = raw.coefficients
            self.ingredientAbsorption = raw.ingredientAbsorption
            self.oilPerGramKcal = raw.oilPerGramKcal
        } else {
            // 安全兜底：不 fatalError，使用文献默认值
            self.coefficients = [
                MethodCoefficient(method: "steam", label: "清蒸", min: 1.0, max: 1.05, default: 1.0, oilAdded: false, defaultOilG: 0, description: "几乎不额外加油"),
                MethodCoefficient(method: "boil", label: "水煮", min: 1.0, max: 1.05, default: 1.0, oilAdded: false, defaultOilG: 0, description: "清水煮，无额外油"),
                MethodCoefficient(method: "coldDress", label: "凉拌", min: 1.0, max: 1.2, default: 1.05, oilAdded: true, defaultOilG: 3, description: "少量香油"),
                MethodCoefficient(method: "stirFry", label: "爆炒", min: 1.1, max: 1.3, default: 1.2, oilAdded: true, defaultOilG: 8, description: "高温快炒"),
                MethodCoefficient(method: "braise", label: "红烧", min: 1.2, max: 1.5, default: 1.3, oilAdded: true, defaultOilG: 10, description: "先煎后炖"),
                MethodCoefficient(method: "dryFry", label: "干煸/干锅", min: 1.4, max: 1.8, default: 1.6, oilAdded: true, defaultOilG: 15, description: "油煸至干"),
                MethodCoefficient(method: "deepFry", label: "煎炸", min: 1.5, max: 3.0, default: 2.0, oilAdded: true, defaultOilG: 20, description: "油炸"),
                MethodCoefficient(method: "roast", label: "烤", min: 1.0, max: 1.2, default: 1.05, oilAdded: false, defaultOilG: 0, description: "干烤不加油"),
                MethodCoefficient(method: "stew", label: "炖", min: 1.0, max: 1.2, default: 1.05, oilAdded: false, defaultOilG: 2, description: "慢炖"),
            ]
            self.ingredientAbsorption = [
                IngredientAbsorption(keywords: ["茄子", "豆腐", "油豆腐", "腐竹", "油条"], absorptionFactor: 1.5, note: "高吸油多孔食材"),
                IngredientAbsorption(keywords: ["土豆", "山药", "莲藕", "南瓜", "芋头"], absorptionFactor: 1.2, note: "淀粉类多孔食材"),
                IngredientAbsorption(keywords: ["鸡蛋"], absorptionFactor: 1.3, note: "炒鸡蛋吸油多"),
                IngredientAbsorption(keywords: ["面", "粉", "面包", "裹粉", "面糊", "饼"], absorptionFactor: 1.4, note: "面衣油炸吸油"),
            ]
            self.oilPerGramKcal = 9.0
            #if DEBUG
            print("[WARN] cooking_coefficients.json 加载失败，使用内置默认值")
            #endif
        }
    }

    subscript(method: String) -> MethodCoefficient {
        coefficients.first { $0.method == method } ?? MethodCoefficient.defaultValue
    }

    func absorptionFactor(for foodName: String) -> Double {
        for entry in ingredientAbsorption {
            if entry.keywords.contains(where: { foodName.contains($0) }) {
                return entry.absorptionFactor
            }
        }
        return 1.0
    }
}

// MARK: - JSON 模型

struct RawTable: Codable {
    let coefficients: [MethodCoefficient]
    let oilPerGramKcal: Double
    let ingredientAbsorption: [IngredientAbsorption]
}

struct MethodCoefficient: Codable {
    let method: String
    let label: String
    let min: Double
    let max: Double
    let `default`: Double
    let oilAdded: Bool
    let defaultOilG: Double
    let description: String

    static let defaultValue = MethodCoefficient(
        method: "unknown",
        label: "未知",
        min: 1.0,
        max: 1.5,
        default: 1.2,
        oilAdded: true,
        defaultOilG: 8,
        description: "未知烹饪方式，使用默认系数"
    )
}

struct IngredientAbsorption: Codable {
    let keywords: [String]
    let absorptionFactor: Double
    let note: String
}