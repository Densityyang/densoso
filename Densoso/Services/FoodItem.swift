import Foundation
import GRDB

/// 本地食物成分记录。来源与许可字段用于保留可追溯信息；缺失字段表示旧测试夹具。
struct FoodItem: Codable, FetchableRecord, PersistableRecord {
    var id: Int64
    var name: String
    var alias: String?
    var preparation: String?
    var isCookedComposite: Bool?
    var category: String
    var edible: Int                // 食部 (%)
    var energyKcal: Int            // kcal / 100g
    var proteinG: Double?
    var fatG: Double?
    var carbohydrateG: Double?
    var fiberG: Double?
    var energyRaw: String? = nil
    var energyUnit: String? = nil
    var sourceID: String? = nil
    var sourceRecordID: String? = nil
    var sourceVersion: String? = nil
    var licenseStatus: String? = nil
    var sourceRecordJSON: String? = nil
    var importWarningsJSON: String? = nil

    static let databaseTableName = "food_items"

    /// 食部修正后的热量
    var adjustedEnergyKcal: Double {
        Double(energyKcal) * Double(edible) / 100.0
    }
}
