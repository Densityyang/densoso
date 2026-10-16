import Foundation

enum DraftError: LocalizedError {
    case invalidMeal
    case ambiguousFood(name: String, candidates: [String])
    case invalidWeight
    case invalidWorkoutPlan
    case invalidDailyCheckIn
    case invalidUserPreference

    var errorDescription: String? {
        switch self {
        case .invalidMeal: "餐食草稿字段不完整或超出允许范围"
        case .ambiguousFood(let name, let candidates):
            "食材“\(name)”需要确认候选：\(candidates.joined(separator: "、"))"
        case .invalidWeight: "体重草稿字段不完整或超出允许范围"
        case .invalidWorkoutPlan: "训练计划草稿字段不完整或超出允许范围"
        case .invalidDailyCheckIn: "每日状态草稿字段不完整或超出允许范围"
        case .invalidUserPreference: "用户偏好草稿字段不完整或超出允许范围"
        }
    }
}
