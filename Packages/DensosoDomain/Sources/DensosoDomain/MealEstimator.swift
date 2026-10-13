import Foundation

public struct MealIngredientEstimationInput: Codable, Equatable, Sendable {
    public let label: String
    public let resolution: FoodResolution
    public let portion: PortionEstimate
    public let massBasis: FoodMassBasis
    public let additionalEvidence: [EvidenceSnapshot]

    public init(
        label: String,
        resolution: FoodResolution,
        portion: PortionEstimate,
        massBasis: FoodMassBasis,
        additionalEvidence: [EvidenceSnapshot] = []
    ) {
        self.label = label
        self.resolution = resolution
        self.portion = portion
        self.massBasis = massBasis
        self.additionalEvidence = additionalEvidence
    }
}

public struct MealDishEstimationInput: Codable, Equatable, Sendable {
    public let name: String
    public let cookingMethod: String?
    public let ingredients: [MealIngredientEstimationInput]
    public let inferredOilGrams: EstimateRange?

    public init(
        name: String,
        cookingMethod: String? = nil,
        ingredients: [MealIngredientEstimationInput],
        inferredOilGrams: EstimateRange? = nil
    ) {
        self.name = name
        self.cookingMethod = cookingMethod
        self.ingredients = ingredients
        self.inferredOilGrams = inferredOilGrams
    }
}

public enum MealEstimationError: Error, Equatable, Sendable {
    case noFoodCandidates(label: String)
    case emptyDish
}

public struct CookingOilPriorTable: Sendable {
    public let version: String

    public init(version: String = "cooking-oil-prior-v1") {
        self.version = version
    }

    public func range(for cookingMethod: String?) throws -> EstimateRange? {
        switch cookingMethod?.lowercased() {
        case "stirfry", "炒", "爆炒": try EstimateRange(low: 5, likely: 8, high: 12)
        case "braise", "红烧", "焖": try EstimateRange(low: 8, likely: 12, high: 18)
        case "dryfry", "干煸", "干锅": try EstimateRange(low: 10, likely: 16, high: 24)
        case "deepfry", "炸", "煎炸": try EstimateRange(low: 15, likely: 24, high: 36)
        case "steam", "boil", "stew", "蒸", "煮", "炖", "凉拌": try EstimateRange(low: 0, likely: 0, high: 3)
        case nil, "unknown", "": nil
        default: try EstimateRange(low: 3, likely: 8, high: 15)
        }
    }
}

public struct MealEstimator: Sendable {
    public static let algorithmVersion = "meal-estimator-v1"

    public init() {}

    public func estimateDish(_ input: MealDishEstimationInput) throws -> MealDishDraft {
        guard !input.ingredients.isEmpty else { throw MealEstimationError.emptyDish }
        var ingredients = try input.ingredients.map(estimateIngredient)

        let selectedEntries = input.ingredients.compactMap { $0.resolution.autoPreselect?.entry }
        let allIngredientsResolved = selectedEntries.count == input.ingredients.count
        let hasExplicitOil = selectedEntries.contains {
            FoodResolver.normalize($0.category).contains("oil") || $0.name.contains("油")
        }
        let isCookedComposite = selectedEntries.contains(where: \.isCookedComposite)
        if allIngredientsResolved,
           !hasExplicitOil,
           !isCookedComposite,
           let oil = input.inferredOilGrams {
            ingredients.append(try oilIngredient(oil, cookingMethod: input.cookingMethod))
        }

        let nutrients = try sumNutrients(ingredients.map(\.nutrients))
        let portion = try EstimateRange.sum(ingredients.map(\.amountGrams))
        let evidence = ingredients.flatMap(\.evidence)
        return MealDishDraft(
            name: input.name,
            cookingMethod: input.cookingMethod,
            portionGrams: portion,
            nutrients: nutrients,
            ingredients: ingredients,
            evidence: evidence,
            algorithmVersion: Self.algorithmVersion
        )
    }

    private func estimateIngredient(_ input: MealIngredientEstimationInput) throws -> MealIngredientDraft {
        let candidates = input.resolution.candidates
        guard !candidates.isEmpty else {
            throw MealEstimationError.noFoodCandidates(label: input.label)
        }
        let selectedCandidate = input.resolution.autoPreselect
        let edibleMultiplier: (FoodCatalogEntry) -> Double = { entry in
            input.massBasis == .asPurchased ? entry.edibleFraction : 1
        }

        let energyRanges = try candidates.map { candidate in
            try nutrientRange(
                per100: candidate.entry.nutrients.energyKcalPer100Grams,
                portion: input.portion,
                edibleMultiplier: edibleMultiplier(candidate.entry)
            )
        }
        let likelyEnergyValue: Double
        if let selectedCandidate {
            likelyEnergyValue = try nutrientRange(
                per100: selectedCandidate.entry.nutrients.energyKcalPer100Grams,
                portion: input.portion,
                edibleMultiplier: edibleMultiplier(selectedCandidate.entry)
            ).likely
        } else {
            likelyEnergyValue = Self.median(energyRanges.map(\.likely))
        }
        let energyLow = energyRanges.map(\.low).min() ?? likelyEnergyValue
        let energyHigh = energyRanges.map(\.high).max() ?? likelyEnergyValue
        let energy = try EstimateRange(
            low: energyLow,
            likely: min(max(likelyEnergyValue, energyLow), energyHigh),
            high: energyHigh
        )

        let protein = try optionalEnvelope(
            candidates: candidates,
            selected: selectedCandidate,
            portion: input.portion,
            edibleMultiplier: edibleMultiplier,
            keyPath: \.proteinGramsPer100Grams
        )
        let fat = try optionalEnvelope(
            candidates: candidates,
            selected: selectedCandidate,
            portion: input.portion,
            edibleMultiplier: edibleMultiplier,
            keyPath: \.fatGramsPer100Grams
        )
        let carbohydrates = try optionalEnvelope(
            candidates: candidates,
            selected: selectedCandidate,
            portion: input.portion,
            edibleMultiplier: edibleMultiplier,
            keyPath: \.carbohydrateGramsPer100Grams
        )
        let grade = evidenceGrade(resolution: input.resolution, portion: input.portion)
        let foodID = selectedCandidate?.entry.localFoodID
        let candidateEvidence = selectedCandidate?.evidence
            ?? candidates.flatMap(\.evidence)
        return MealIngredientDraft(
            foodID: foodID,
            name: selectedCandidate?.entry.name ?? input.label,
            amountGrams: try EstimateRange(
                low: input.portion.lowGrams,
                likely: input.portion.likelyGrams,
                high: input.portion.highGrams
            ),
            nutrients: NutrientEstimate(
                energyKcal: energy,
                proteinGrams: protein,
                fatGrams: fat,
                carbohydrateGrams: carbohydrates
            ),
            evidence: candidateEvidence + input.additionalEvidence + input.portion.conflicts.map {
                EvidenceSnapshot(
                    grade: .unresolved,
                    sourceID: "portion-conflict",
                    sourceVersion: Self.algorithmVersion,
                    summary: $0,
                    confidence: nil
                )
            } + [
                EvidenceSnapshot(
                    grade: grade,
                    sourceID: "portion:\(input.portion.source.rawValue)",
                    sourceVersion: Self.algorithmVersion,
                    summary: "约 \(Int(input.portion.likelyGrams.rounded()))g（\(Int(input.portion.lowGrams.rounded()))–\(Int(input.portion.highGrams.rounded()))g）",
                    confidence: nil
                )
            ]
        )
    }

    private func nutrientRange(
        per100: Double,
        portion: PortionEstimate,
        edibleMultiplier: Double
    ) throws -> EstimateRange {
        try EstimateRange(
            low: portion.lowGrams * edibleMultiplier * per100 / 100,
            likely: portion.likelyGrams * edibleMultiplier * per100 / 100,
            high: portion.highGrams * edibleMultiplier * per100 / 100
        )
    }

    private func optionalEnvelope(
        candidates: [FoodCandidate],
        selected: FoodCandidate?,
        portion: PortionEstimate,
        edibleMultiplier: (FoodCatalogEntry) -> Double,
        keyPath: KeyPath<FoodNutrientProfile, Double?>
    ) throws -> EstimateRange? {
        let values = candidates.compactMap { $0.entry.nutrients[keyPath: keyPath] }
        guard values.count == candidates.count else { return nil }
        let ranges = try zip(candidates, values).map { pair in
            let (candidate, value) = pair
            return try nutrientRange(
                per100: value,
                portion: portion,
                edibleMultiplier: edibleMultiplier(candidate.entry)
            )
        }
        let likelyValue: Double
        if let selected,
           let selectedValue = selected.entry.nutrients[keyPath: keyPath] {
            likelyValue = try nutrientRange(
                per100: selectedValue,
                portion: portion,
                edibleMultiplier: edibleMultiplier(selected.entry)
            ).likely
        } else {
            likelyValue = Self.median(ranges.map(\.likely))
        }
        let low = ranges.map(\.low).min() ?? likelyValue
        let high = ranges.map(\.high).max() ?? likelyValue
        return try EstimateRange(
            low: low,
            likely: min(max(likelyValue, low), high),
            high: high
        )
    }

    private func sumNutrients(_ nutrients: [NutrientEstimate]) throws -> NutrientEstimate {
        func sumOptional(_ values: [EstimateRange?]) throws -> EstimateRange? {
            let present = values.compactMap { $0 }
            return present.count == values.count ? try EstimateRange.sum(present) : nil
        }
        return NutrientEstimate(
            energyKcal: try EstimateRange.sum(nutrients.map(\.energyKcal)),
            proteinGrams: try sumOptional(nutrients.map(\.proteinGrams)),
            fatGrams: try sumOptional(nutrients.map(\.fatGrams)),
            carbohydrateGrams: try sumOptional(nutrients.map(\.carbohydrateGrams))
        )
    }

    private func oilIngredient(
        _ grams: EstimateRange,
        cookingMethod: String?
    ) throws -> MealIngredientDraft {
        let energy = try grams.scaled(by: 9)
        return MealIngredientDraft(
            foodID: nil,
            name: "烹饪用油",
            amountGrams: grams,
            nutrients: NutrientEstimate(
                energyKcal: energy,
                proteinGrams: try EstimateRange.point(0),
                fatGrams: grams,
                carbohydrateGrams: try EstimateRange.point(0)
            ),
            evidence: [
                EvidenceSnapshot(
                    grade: .estimated,
                    sourceID: "cooking-oil-prior",
                    sourceVersion: Self.algorithmVersion,
                    summary: "\(cookingMethod ?? "未知烹饪")的用油范围",
                    confidence: nil
                )
            ]
        )
    }

    private func evidenceGrade(
        resolution: FoodResolution,
        portion: PortionEstimate
    ) -> EvidenceGrade {
        if resolution.autoPreselect != nil, portion.isMeasured { return .measured }
        if resolution.autoPreselect != nil,
           [.measured, .userReportedExact, .packageServing].contains(portion.source) { return .strong }
        let width = (portion.highGrams - portion.lowGrams) / max(portion.likelyGrams, 1)
        if resolution.autoPreselect != nil || width <= 0.60 { return .moderate }
        return .weak
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
