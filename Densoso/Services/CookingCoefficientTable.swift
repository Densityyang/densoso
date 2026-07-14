import Foundation

/// 从 cooking_coefficients.json 加载的静态系数表
final class CookingCoefficientTable {
    static let shared = CookingCoefficientTable()

    let coefficients: [MethodCoefficient]
    let ingredientAbsorption: [IngredientAbsorption]
    let oilPerGramKcal: Double

    private init() {
        guard let url = Bundle.main.url(forResource: "cooking_coefficients", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawTable.self, from: data) else {
            fatalError("无法加载 cooking_coefficients.json，请检查文件是否已添加到 Bundle")
        }
        self.coefficients = raw.coefficients
        self.ingredientAbsorption = raw.ingredientAbsorption
        self.oilPerGramKcal = raw.oilPerGramKcal
    }

    /// 取烹饪方式系数
    subscript(method: String) -> MethodCoefficient {
        coefficients.first { $0.method == method } ?? MethodCoefficient.defaultValue
    }

    /// 查找某食材的吸油特性系数
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