import Foundation
import GRDB

/// 本地食材库条目（对应 ChinaFoodComposition 中的一行）
struct FoodItem: Codable, FetchableRecord, PersistableRecord {
    var id: Int64
    var name: String
    var alias: String?
    var category: String
    var edible: Int                // 食部 (%)
    var energyKcal: Int            // kcal / 100g
    var proteinG: Double
    var fatG: Double
    var carbohydrateG: Double
    var fiberG: Double?

    static let databaseTableName = "food_items"

    /// 食部修正后的热量
    var adjustedEnergyKcal: Double {
        Double(energyKcal) * Double(edible) / 100.0
    }
}