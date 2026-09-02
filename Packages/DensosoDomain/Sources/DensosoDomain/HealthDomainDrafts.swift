import Foundation

public struct MealIngredientDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let foodID: String?
    public let name: String
    public let amountGrams: EstimateRange
    public let nutrients: NutrientEstimate
    public let evidence: [EvidenceSnapshot]

    public init(
        id: UUID = UUID(),
        foodID: String? = nil,
        name: String,
        amountGrams: EstimateRange,
        nutrients: NutrientEstimate,
        evidence: [EvidenceSnapshot] = []
    ) {
        self.id = id
        self.foodID = foodID
        self.name = name
        self.amountGrams = amountGrams
        self.nutrients = nutrients
        self.evidence = evidence
    }
}

public struct MealDishDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let cookingMethod: String?
    public let portionGrams: EstimateRange?
    public let nutrients: NutrientEstimate
    public let ingredients: [MealIngredientDraft]
    public let evidence: [EvidenceSnapshot]
    public let algorithmVersion: String

    public init(
        id: UUID = UUID(),
        name: String,
        cookingMethod: String? = nil,
        portionGrams: EstimateRange? = nil,
        nutrients: NutrientEstimate,
        ingredients: [MealIngredientDraft] = [],
        evidence: [EvidenceSnapshot] = [],
        algorithmVersion: String
    ) {
        self.id = id
        self.name = name
        self.cookingMethod = cookingMethod
        self.portionGrams = portionGrams
        self.nutrients = nutrients
        self.ingredients = ingredients
        self.evidence = evidence
        self.algorithmVersion = algorithmVersion
    }
}

public struct MealDraft: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let mealType: String
    public let dishes: [MealDishDraft]
    public let note: String?

    public init(
        occurredAt: Date,
        mealType: String,
        dishes: [MealDishDraft],
        note: String? = nil
    ) {
        self.occurredAt = occurredAt
        self.mealType = mealType
        self.dishes = dishes
        self.note = note
    }

    public var totalNutrients: NutrientEstimate? {
        guard !dishes.isEmpty,
              let energy = try? EstimateRange.sum(dishes.map(\.nutrients.energyKcal)) else {
            return nil
        }
        return NutrientEstimate(
            energyKcal: energy,
            proteinGrams: sumOptional(\.proteinGrams),
            fatGrams: sumOptional(\.fatGrams),
            carbohydrateGrams: sumOptional(\.carbohydrateGrams)
        )
    }

    private func sumOptional(_ keyPath: KeyPath<NutrientEstimate, EstimateRange?>) -> EstimateRange? {
        let values = dishes.compactMap { $0.nutrients[keyPath: keyPath] }
        guard values.count == dishes.count else { return nil }
        return try? EstimateRange.sum(values)
    }
}

public struct WeightDraft: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let kilograms: Double
    public let source: String

    public init(measuredAt: Date, kilograms: Double, source: String = "manual") {
        self.measuredAt = measuredAt
        self.kilograms = kilograms
        self.source = source
    }
}

public struct GoalProfile: Codable, Equatable, Sendable {
    public let effectiveFrom: Date
    public let targetWeightKilograms: Double?
    public let dailyDeficitKcal: Int?
    public let dailyProteinGrams: Double?

    public init(
        effectiveFrom: Date,
        targetWeightKilograms: Double? = nil,
        dailyDeficitKcal: Int? = nil,
        dailyProteinGrams: Double? = nil
    ) {
        self.effectiveFrom = effectiveFrom
        self.targetWeightKilograms = targetWeightKilograms
        self.dailyDeficitKcal = dailyDeficitKcal
        self.dailyProteinGrams = dailyProteinGrams
    }
}

public struct DailyHealthSnapshot: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let timezoneIdentifier: String
    public let energyIntakeKcal: EstimateRange?
    public let activeEnergyKcal: Double?
    public let weightKilograms: Double?
    public let algorithmVersion: String

    public init(
        dayStart: Date,
        timezoneIdentifier: String,
        energyIntakeKcal: EstimateRange? = nil,
        activeEnergyKcal: Double? = nil,
        weightKilograms: Double? = nil,
        algorithmVersion: String
    ) {
        self.dayStart = dayStart
        self.timezoneIdentifier = timezoneIdentifier
        self.energyIntakeKcal = energyIntakeKcal
        self.activeEnergyKcal = activeEnergyKcal
        self.weightKilograms = weightKilograms
        self.algorithmVersion = algorithmVersion
    }
}
