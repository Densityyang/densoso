import DensosoDomain
import Foundation

struct PersonalMealPortionPrior: Equatable, Identifiable, Sendable {
    let id: UUID
    let priorKey: String
    let foodID: String?
    let foodName: String
    let prior: HouseholdPortionPrior
    let sourceActionKey: String?
    let createdAt: Date
    let updatedAt: Date
}

struct PersonalMealPortionPriorEdit: Equatable, Sendable {
    let id: UUID?
    let foodID: String?
    let foodName: String
    let unit: String
    let gramsPerUnit: Double

    init(id: UUID?, foodID: String? = nil, foodName: String, unit: String, gramsPerUnit: Double) {
        self.id = id
        self.foodID = foodID
        self.foodName = foodName
        self.unit = unit
        self.gramsPerUnit = gramsPerUnit
    }
}

protocol MealPortionPriorRepository: Sendable {
    func all() async throws -> [PersonalMealPortionPrior]
    func prior(foodID: String?, foodName: String, unit: String) async throws -> HouseholdPortionPrior?
    func save(_ edit: PersonalMealPortionPriorEdit) async throws
    func delete(id: UUID) async throws
}

enum MealPortionPriorRepositoryError: Error, Equatable {
    case invalidValue
    case duplicateFoodAndUnit
    case notFound
}

enum MealPortionPriorStorageKey {
    static func make(foodID: String?, foodName: String, unit: String) -> String? {
        guard let normalizedUnit = MealPortionPriorCorrection.normalizeSupportedUnit(unit) else {
            return nil
        }
        let identity: String
        if let foodID = foodID?.trimmingCharacters(in: .whitespacesAndNewlines), !foodID.isEmpty {
            identity = "id:\(foodID.lowercased())"
        } else {
            let normalizedName = FoodResolver.normalize(foodName)
            guard !normalizedName.isEmpty else { return nil }
            identity = "name:\(normalizedName)"
        }
        return "\(identity)|unit:\(normalizedUnit)"
    }
}

enum MealPortionPriorPresentation {
    static func unitLabel(_ unit: String) -> String {
        guard let canonicalUnit = MealPortionPriorCorrection.normalizeSupportedUnit(unit) else {
            return unit
        }
        switch canonicalUnit {
        case "bowl": "碗"
        case "smallbowl": "小碗"
        case "largebowl": "大碗"
        case "fist": "拳头"
        case "palm": "掌心"
        case "cup": "杯"
        case "slice": "片"
        case "egg": "个鸡蛋"
        case "dumpling": "个饺子"
        case "banana": "根香蕉"
        case "apple": "个苹果"
        default: unit
        }
    }
}
