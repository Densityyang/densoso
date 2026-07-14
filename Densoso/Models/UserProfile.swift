import Foundation
import SwiftData

@Model
final class UserProfile {
    var name: String
    var biologicalSex: String
    var dateOfBirth: Date
    var heightCm: Double
    var weightKg: Double
    var weightHistoryJSON: String    // JSON: [{date, kg}]
    var activityLevel: String
    var dailyDeficitTarget: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String = "",
        biologicalSex: String = "male",
        dateOfBirth: Date = Date(timeIntervalSince1970: 0),
        heightCm: Double = 170.0,
        weightKg: Double = 70.0,
        activityLevel: String = "sedentary",
        dailyDeficitTarget: Int = 500
    ) {
        self.name = name
        self.biologicalSex = biologicalSex
        self.dateOfBirth = dateOfBirth
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.weightHistoryJSON = "[]"
        self.activityLevel = activityLevel
        self.dailyDeficitTarget = dailyDeficitTarget
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - 体重历史

    struct WeightEntry: Codable, Equatable {
        var date: Date
        var kg: Double
    }

    var weightHistory: [WeightEntry] {
        get {
            guard let data = weightHistoryJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([WeightEntry].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                weightHistoryJSON = json
            }
        }
    }

    /// 更新体重并追加历史
    func updateWeight(_ newKg: Double) {
        var history = weightHistory
        history.append(WeightEntry(date: Date(), kg: newKg))
        weightHistory = history
        weightKg = newKg
        updatedAt = Date()
    }

    /// 年龄（从出生日期算）
    var age: Int {
        Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year ?? 30
    }
}