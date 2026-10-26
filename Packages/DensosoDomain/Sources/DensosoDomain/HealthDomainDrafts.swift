import Foundation

public enum ConsumedFractionSource: String, Codable, Equatable, Sendable {
    case currentUserReport
}

/// A meal-wide consumed fraction parsed from explicit text in the current user turn.
public struct ConsumedFractionEvidence: Codable, Equatable, Sendable {
    public static let currentParserVersion = "meal-consumed-fraction-v1"

    public let fraction: Double
    public let source: ConsumedFractionSource
    public let parserVersion: String

    public init?(fraction: Double) {
        guard fraction.isFinite, fraction > 0, fraction <= 1 else { return nil }
        self.fraction = fraction
        source = .currentUserReport
        parserVersion = Self.currentParserVersion
    }

    public var evidenceSnapshot: EvidenceSnapshot {
        let percent = Int((fraction * 100).rounded())
        return EvidenceSnapshot(
            grade: .userReported,
            sourceID: "meal-consumed-fraction:user-report",
            sourceVersion: parserVersion,
            summary: "用户本轮明确自述本餐摄入约 \(percent)%"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case fraction
        case source
        case parserVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fraction = try container.decode(Double.self, forKey: .fraction)
        let source = try container.decode(ConsumedFractionSource.self, forKey: .source)
        let parserVersion = try container.decode(String.self, forKey: .parserVersion)
        guard fraction.isFinite, fraction > 0, fraction <= 1,
              !parserVersion.isEmpty, parserVersion.count <= 80 else {
            throw DecodingError.dataCorruptedError(
                forKey: .fraction,
                in: container,
                debugDescription: "Consumed fraction evidence is out of range."
            )
        }
        self.fraction = fraction
        self.source = source
        self.parserVersion = parserVersion
    }
}

public enum MealDraftScalingError: Error, Equatable, Sendable {
    case consumedFractionAlreadyApplied
}

public struct MealIngredientDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let foodID: String?
    public let name: String
    public let amountGrams: EstimateRange
    public let nutrients: NutrientEstimate
    public let evidence: [EvidenceSnapshot]
    public let foodResolutionScoreV2: FoodResolutionScore?

    public init(
        id: UUID = UUID(),
        foodID: String? = nil,
        name: String,
        amountGrams: EstimateRange,
        nutrients: NutrientEstimate,
        evidence: [EvidenceSnapshot] = [],
        foodResolutionScoreV2: FoodResolutionScore? = nil
    ) {
        self.id = id
        self.foodID = foodID
        self.name = name
        self.amountGrams = amountGrams
        self.nutrients = nutrients
        self.evidence = evidence
        self.foodResolutionScoreV2 = foodResolutionScoreV2
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
    public let consumedFractionEvidence: ConsumedFractionEvidence?

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
        self.consumedFractionEvidence = nil
    }

    private init(
        occurredAt: Date,
        mealType: String,
        dishes: [MealDishDraft],
        note: String?,
        consumedFractionEvidence: ConsumedFractionEvidence
    ) {
        self.occurredAt = occurredAt
        self.mealType = mealType
        self.dishes = dishes
        self.note = note
        self.consumedFractionEvidence = consumedFractionEvidence
    }

    public func applyingConsumedFraction(
        _ evidence: ConsumedFractionEvidence
    ) throws -> MealDraft {
        guard consumedFractionEvidence == nil else {
            throw MealDraftScalingError.consumedFractionAlreadyApplied
        }
        let fraction = evidence.fraction
        let scaledDishes = try dishes.map { dish in
            let scaledIngredients = try dish.ingredients.map { ingredient in
                MealIngredientDraft(
                    id: ingredient.id,
                    foodID: ingredient.foodID,
                    name: ingredient.name,
                    amountGrams: try ingredient.amountGrams.scaled(by: fraction),
                    nutrients: try Self.scaled(ingredient.nutrients, by: fraction),
                    evidence: ingredient.evidence,
                    foodResolutionScoreV2: ingredient.foodResolutionScoreV2
                )
            }
            return MealDishDraft(
                id: dish.id,
                name: dish.name,
                cookingMethod: dish.cookingMethod,
                portionGrams: try dish.portionGrams.map { try $0.scaled(by: fraction) },
                nutrients: try Self.scaled(dish.nutrients, by: fraction),
                ingredients: scaledIngredients,
                evidence: dish.evidence + [evidence.evidenceSnapshot],
                algorithmVersion: dish.algorithmVersion
            )
        }
        return MealDraft(
            occurredAt: occurredAt,
            mealType: mealType,
            dishes: scaledDishes,
            note: note,
            consumedFractionEvidence: evidence
        )
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

    public var caloriePresentation: CaloriePresentation? {
        guard let energy = totalNutrients?.energyKcal else { return nil }
        return CaloriePresentationPolicy().presentation(for: energy)
    }

    private func sumOptional(_ keyPath: KeyPath<NutrientEstimate, EstimateRange?>) -> EstimateRange? {
        let values = dishes.compactMap { $0.nutrients[keyPath: keyPath] }
        guard values.count == dishes.count else { return nil }
        return try? EstimateRange.sum(values)
    }

    private static func scaled(_ estimate: NutrientEstimate, by fraction: Double) throws -> NutrientEstimate {
        NutrientEstimate(
            energyKcal: try estimate.energyKcal.scaled(by: fraction),
            proteinGrams: try estimate.proteinGrams.map { try $0.scaled(by: fraction) },
            fatGrams: try estimate.fatGrams.map { try $0.scaled(by: fraction) },
            carbohydrateGrams: try estimate.carbohydrateGrams.map { try $0.scaled(by: fraction) }
        )
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
    public static let currentAlgorithmVersion = "daily-health-snapshot-v2"

    public let dayStart: Date
    public let timezoneIdentifier: String
    public let energyIntakeKcal: EstimateRange?
    public let activeEnergyKcal: Double?
    public let restingEnergyKcal: Double?
    public let stepCount: Double?
    public let exerciseMinutes: Double?
    public let weightKilograms: Double?
    /// Transient samples decoded from V1-V5 payloads; never encoded by the V2 cache.
    public let healthKitSamples: [HealthSampleSnapshot]?
    public let healthKitSampleSummary: DailyHealthSampleSummary?
    public let healthReadStates: [String: HealthReadState]?
    public let algorithmVersion: String

    public var activeEnergyForProjection: Double? {
        guard healthReadStates?[HealthMetricID.activeEnergy.rawValue] == .available else { return nil }
        return activeEnergyKcal
    }

    public var restingEnergyForProjection: Double? {
        guard healthReadStates?[HealthMetricID.restingEnergy.rawValue] == .available else { return nil }
        return restingEnergyKcal
    }

    public var stepCountForProjection: Double? {
        guard healthReadStates?[HealthMetricID.stepCount.rawValue] == .available else { return nil }
        return stepCount
    }

    public var exerciseMinutesForProjection: Double? {
        guard healthReadStates?[HealthMetricID.exerciseMinutes.rawValue] == .available else { return nil }
        return exerciseMinutes
    }

    public init(
        dayStart: Date,
        timezoneIdentifier: String,
        energyIntakeKcal: EstimateRange? = nil,
        activeEnergyKcal: Double? = nil,
        restingEnergyKcal: Double? = nil,
        stepCount: Double? = nil,
        exerciseMinutes: Double? = nil,
        weightKilograms: Double? = nil,
        healthKitSamples: [HealthSampleSnapshot]? = nil,
        healthKitSampleSummary: DailyHealthSampleSummary? = nil,
        healthReadStates: [String: HealthReadState]? = nil,
        algorithmVersion: String
    ) {
        self.dayStart = dayStart
        self.timezoneIdentifier = timezoneIdentifier
        self.energyIntakeKcal = energyIntakeKcal
        self.activeEnergyKcal = activeEnergyKcal
        self.restingEnergyKcal = restingEnergyKcal
        self.stepCount = stepCount
        self.exerciseMinutes = exerciseMinutes
        self.weightKilograms = weightKilograms
        self.healthKitSamples = healthKitSamples
        self.healthKitSampleSummary = healthKitSampleSummary
            ?? healthKitSamples.map { DailyHealthSampleSummary(samples: $0, dayStart: dayStart) }
        self.healthReadStates = Self.inferredReadStates(healthReadStates, from: healthKitSamples)
        self.algorithmVersion = algorithmVersion
    }

    private enum CodingKeys: String, CodingKey {
        case dayStart
        case timezoneIdentifier
        case energyIntakeKcal
        case activeEnergyKcal
        case restingEnergyKcal
        case stepCount
        case exerciseMinutes
        case weightKilograms
        case healthKitSamples
        case healthKitSampleSummary
        case healthReadStates
        case algorithmVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedDayStart = try container.decode(Date.self, forKey: .dayStart)
        dayStart = decodedDayStart
        timezoneIdentifier = try container.decode(String.self, forKey: .timezoneIdentifier)
        energyIntakeKcal = try container.decodeIfPresent(EstimateRange.self, forKey: .energyIntakeKcal)
        activeEnergyKcal = try container.decodeIfPresent(Double.self, forKey: .activeEnergyKcal)
        restingEnergyKcal = try container.decodeIfPresent(Double.self, forKey: .restingEnergyKcal)
        stepCount = try container.decodeIfPresent(Double.self, forKey: .stepCount)
        exerciseMinutes = try container.decodeIfPresent(Double.self, forKey: .exerciseMinutes)
        weightKilograms = try container.decodeIfPresent(Double.self, forKey: .weightKilograms)
        let legacySamples = try container.decodeIfPresent([HealthSampleSnapshot].self, forKey: .healthKitSamples)
        healthKitSamples = legacySamples
        let decodedSampleSummary = try container.decodeIfPresent(
            DailyHealthSampleSummary.self,
            forKey: .healthKitSampleSummary
        ) ?? legacySamples.map { DailyHealthSampleSummary(samples: $0, dayStart: decodedDayStart) }
        healthKitSampleSummary = decodedSampleSummary
        let storedReadStates = try container.decodeIfPresent([String: HealthReadState].self, forKey: .healthReadStates)
        healthReadStates = Self.inferredReadStates(storedReadStates, from: legacySamples)
        algorithmVersion = try container.decode(String.self, forKey: .algorithmVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayStart, forKey: .dayStart)
        try container.encode(timezoneIdentifier, forKey: .timezoneIdentifier)
        try container.encodeIfPresent(energyIntakeKcal, forKey: .energyIntakeKcal)
        try container.encodeIfPresent(activeEnergyKcal, forKey: .activeEnergyKcal)
        try container.encodeIfPresent(restingEnergyKcal, forKey: .restingEnergyKcal)
        try container.encodeIfPresent(stepCount, forKey: .stepCount)
        try container.encodeIfPresent(exerciseMinutes, forKey: .exerciseMinutes)
        try container.encodeIfPresent(weightKilograms, forKey: .weightKilograms)
        try container.encodeIfPresent(healthKitSampleSummary, forKey: .healthKitSampleSummary)
        try container.encodeIfPresent(healthReadStates, forKey: .healthReadStates)
        try container.encode(algorithmVersion, forKey: .algorithmVersion)
    }

    private static func inferredReadStates(
        _ stored: [String: HealthReadState]?,
        from samples: [HealthSampleSnapshot]?
    ) -> [String: HealthReadState]? {
        var states = stored ?? [:]
        for metric in Set(samples?.map(\.metric) ?? []) where states[metric.rawValue] == nil {
            states[metric.rawValue] = .available
        }
        return states.isEmpty ? nil : states
    }
}
