import Foundation

enum DraftError: LocalizedError {
    case invalidMeal
    case invalidWeight
    case invalidWorkoutPlan

    var errorDescription: String? {
        switch self {
        case .invalidMeal: "餐食草稿字段不完整或超出允许范围"
        case .invalidWeight: "体重草稿字段不完整或超出允许范围"
        case .invalidWorkoutPlan: "训练计划草稿字段不完整或超出允许范围"
        }
    }
}
