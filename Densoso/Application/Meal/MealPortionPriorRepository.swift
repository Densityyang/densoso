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

struct PersonalMealDishPriorEdit: Equatable, Sendable {
    let id: UUID?
    let dishName: String
    let cookingMethod: String?
    let ingredients: [PersonalMealDishIngredientPrior]

    init(
        id: UUID?,
        dishName: String,
        cookingMethod: String? = nil,
        ingredients: [PersonalMealDishIngredientPrior]
    ) {
        self.id = id
        self.dishName = dishName
        self.cookingMethod = cookingMethod
        self.ingredients = ingredients
    }
}

protocol MealPortionPriorRepository: Sendable {
    func all() async throws -> [PersonalMealPortionPrior]
    func prior(foodID: String?, foodName: String, unit: String) async throws -> HouseholdPortionPrior?
    func save(_ edit: PersonalMealPortionPriorEdit) async throws
    func delete(id: UUID) async throws
    func allDishPriors() async throws -> [PersonalMealDishPrior]
    func dishPrior(named: String, cookingMethod: String?) async throws -> PersonalMealDishPrior?
    func saveDishPrior(_ edit: PersonalMealDishPriorEdit) async throws
    func deleteDishPrior(id: UUID) async throws
}

enum MealPortionPriorRepositoryError: Error, Equatable {
    case invalidValue
    case duplicateFoodAndUnit
    case duplicateDishAndIngredients
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

enum MealDishPriorStorageKey {
    static func dishKey(_ dishName: String) -> String? {
        let key = FoodResolver.normalize(dishName)
        return key.isEmpty ? nil : key
    }

    static func cookingMethodKey(_ cookingMethod: String?) -> String {
        guard let cookingMethod else { return "unknown" }
        let normalized = FoodResolver.normalize(cookingMethod)
        return normalized.isEmpty ? "unknown" : normalized
    }

    static func make(
        dishName: String,
        cookingMethod: String?,
        ingredients: [PersonalMealDishIngredientPrior]
    ) -> (priorKey: String, dishKey: String, cookingMethodKey: String)? {
        guard let dishKey = dishKey(dishName), !ingredients.isEmpty,
              ingredients.count <= 20 else { return nil }
        let ingredientKeys = ingredients.map(\.id).sorted()
        guard Set(ingredientKeys).count == ingredientKeys.count else { return nil }
        let methodKey = cookingMethodKey(cookingMethod)
        let compositionKey = ingredientKeys.joined(separator: ",")
        return (
            "dish:\(dishKey)|method:\(methodKey)|ingredients:\(compositionKey)",
            dishKey,
            methodKey
        )
    }
}

enum MealPortionPriorPresentation {
    static func unitLabel(_ unit: String) -> String {
        guard let canonicalUnit = MealPortionPriorCorrection.normalizeSupportedUnit(unit) else {
            return unit
        }
        switch canonicalUnit {
        case "bowl": return "碗"
        case "smallbowl": return "小碗"
        case "largebowl": return "大碗"
        case "fist": return "拳头"
        case "palm": return "掌心"
        case "cup": return "杯"
        case "slice": return "片"
        case "egg": return "个鸡蛋"
        case "dumpling": return "个饺子"
        case "banana": return "根香蕉"
        case "apple": return "个苹果"
        default: return unit
        }
    }
}
