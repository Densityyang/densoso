import DensosoDomain
import Foundation

struct LogMealTool: ConfirmationRequiredTool {
    var definition: ToolSchema {
        .strictObject(
            name: "log_meal",
            description: "准备一餐草稿，不会保存；食材候选、生熟和区间必须通过本地解析与确认。",
            effect: .stagesAction,
            properties: [
                "mealType": .string(
                    allowedValues: ["breakfast", "lunch", "dinner", "snack"]
                ),
                "occurredAt": .anyOf([.string(format: "date-time"), .null]),
                "dishes": .array(
                    items: .object(
                        properties: [
                            "dishName": .string(minimumLength: 1, maximumLength: 120),
                            "cookingMethod": .string(
                                allowedValues: [
                                    "steam", "boil", "coldDress", "stirFry", "braise",
                                    "dryFry", "deepFry", "roast", "stew", "unknown",
                                ]
                            ),
                            "ingredients": .array(
                                items: .object(
                                    properties: [
                                        "name": .string(minimumLength: 1, maximumLength: 120),
                                        "quantityEvidence": .object(
                                            properties: [
                                                "kind": .string(allowedValues: [
                                                    "exactGrams", "household", "count", "packageServing",
                                                    "photoEstimate", "unknown",
                                                ]),
                                                "value": .anyOf([
                                                    .number(minimum: 0.1, maximum: 5_000), .null,
                                                ]),
                                                "unit": .anyOf([
                                                    .string(allowedValues: [
                                                        "g", "gram", "grams", "克", "公克",
                                                        "bowl", "smallBowl", "largeBowl", "fist", "palm", "cup", "slice",
                                                        "egg", "dumpling", "banana", "apple", "serving", "portion",
                                                        "pack", "package", "碗", "小碗", "大碗", "拳", "拳头", "掌心", "掌",
                                                        "杯", "片", "鸡蛋", "蛋", "饺子", "香蕉", "苹果", "份", "每份", "包",
                                                    ]),
                                                    .null,
                                                ]),
                                                "gramsPerServing": .anyOf([
                                                    .number(minimum: 0.1, maximum: 5_000), .null,
                                                ]),
                                            ],
                                            required: ["kind", "value", "unit", "gramsPerServing"],
                                            additionalProperties: false,
                                            description: "模型给出的份量线索，不是事实克重；精确克重必须能从当前用户原话本地验证。"
                                        ),
                                        "preparation": .anyOf([
                                            .string(allowedValues: ["raw", "cooked", "unknown"]),
                                            .null,
                                        ]),
                                        "massBasis": .anyOf([
                                            .string(allowedValues: ["asPurchased", "edibleRaw", "cooked"]),
                                            .null,
                                        ]),
                                    ],
                                    required: ["name", "quantityEvidence"],
                                    additionalProperties: false
                                ),
                                minimumItems: 1,
                                maximumItems: 20
                            ),
                            "lowConfidence": .boolean(),
                        ],
                        required: [
                            "dishName", "cookingMethod", "ingredients", "lowConfidence",
                        ],
                        additionalProperties: false
                    ),
                    minimumItems: 1,
                    maximumItems: 20
                ),
                "note": .anyOf([.string(maximumLength: 1_000), .null]),
            ],
            required: ["mealType", "occurredAt", "dishes", "note"]
        )
    }

    func prepare(argumentsJSON: String, context: AgentSession) async throws -> ActionPayload {
        guard let data = argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(LogMealArguments.self, from: data),
              Set(["breakfast", "lunch", "dinner", "snack"]).contains(arguments.mealType),
              !arguments.dishes.isEmpty,
              arguments.dishes.count <= 20,
              let database = context.foodDatabase else {
            throw DraftError.invalidMeal
        }

        let date: Date
        if let occurredAt = arguments.occurredAt {
            guard let parsed = ISO8601DateFormatter().date(from: occurredAt) else {
                throw DraftError.invalidMeal
            }
            date = parsed
        } else {
            date = Date()
        }

        guard !context.hasIssuedMealClarification() else {
            throw DraftError.clarificationLimitReached
        }
        let resolver = FoodResolverV2(catalog: try database.catalogEntries())
        let portionEstimator = PortionEstimator()
        let mealEstimator = MealEstimator()
        let oilPriors = CookingOilPriorTable()
        let quantityResolver = MealQuantityEvidenceResolver()
        let explicitGramsParser = ExplicitUserGramsParser()
        let packageServingParser = PackageServingGramsParser()
        let userText = context.currentMealUserText()
        let agentImageEvidence = context.currentMealImageEvidence()
        let hasPhotoPortionEstimate = context.currentMealHasImage() && arguments.dishes
            .flatMap(\.ingredients)
            .contains { $0.quantityEvidence.kind == .photoEstimate }
        let packageLabelTexts = agentImageEvidence
            .filter { $0.kind == .nutritionLabel }
            .map(\.value)
        let allIngredientNames = arguments.dishes.flatMap { $0.ingredients.map(\.name) }
        var drafts: [MealDishDraft] = []
        for rawDish in arguments.dishes {
            let name = rawDish.dishName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !rawDish.ingredients.isEmpty,
                  rawDish.ingredients.count <= 20,
                  rawDish.ingredients.allSatisfy({
                      !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }),
                  rawDish.cookingMethod.count <= 40 else {
                throw DraftError.invalidMeal
            }

            var ingredients: [MealIngredientEstimationInput] = []
            for (ingredientIndex, ingredient) in rawDish.ingredients.enumerated() {
                let preparation = FoodPreparation(rawValue: ingredient.preparation ?? "") ?? .unknown
                let massBasis = FoodMassBasis(rawValue: ingredient.massBasis ?? "")
                    ?? (preparation == .cooked ? .cooked : .edibleRaw)
                let confirmedHistory = await context.confirmedFoodIDs(matching: ingredient.name)
                let resolution = resolver.resolve(
                    FoodResolutionV2Query(
                        label: ingredient.name,
                        preparation: preparation,
                        massBasis: massBasis,
                        sourceQuality: rawDish.lowConfidence ? 0.7 : 1,
                        confirmedHistoryFoodIDs: confirmedHistory,
                        evidence: agentImageEvidence
                    )
                ).mealEstimatorResolution
                guard !resolution.candidates.isEmpty else {
                    throw DraftError.clarificationRequired(
                        field: "foodIdentity",
                        question: "“\(ingredient.name)”具体是什么食物？",
                        subject: ingredient.name
                    )
                }
                guard let selectedFood = resolution.autoPreselect else {
                    throw DraftError.ambiguousFood(
                        name: ingredient.name,
                        candidates: resolution.candidates.map { $0.entry.name }
                    )
                }
                let ingredientTerms = [ingredient.name, selectedFood.entry.name] + selectedFood.entry.aliases
                let validatedPackageServingGrams = uniquePackageServingGrams(
                    in: userText,
                    imageLabelTexts: packageLabelTexts,
                    matching: ingredientTerms,
                    otherIngredientNames: allIngredientNames.filter { $0 != ingredient.name },
                    parser: packageServingParser
                )
                let userReportedGrams = explicitGramsParser.exactGrams(
                    in: userText,
                    matching: ingredientTerms
                )
                let quantityEvidence: MealQuantityEvidence
                if ingredient.quantityEvidence.kind == .photoEstimate,
                   !context.currentMealHasImage(),
                   userReportedGrams == nil {
                    guard context.currentMealClarificationWasAnswered() else {
                        throw DraftError.clarificationRequired(
                            field: "quantityEvidence",
                            question: "当前请求没有附带照片；请告诉我“\(ingredient.name)”大约有多少份量？",
                            subject: ingredient.name
                        )
                    }
                    quantityEvidence = MealQuantityEvidence(
                        kind: .unknown,
                        value: ingredient.quantityEvidence.value,
                        unit: ingredient.quantityEvidence.unit
                    )
                } else {
                    quantityEvidence = ingredient.quantityEvidence
                }
                let portionEvidence: PortionEvidence
                do {
                    portionEvidence = try quantityResolver.resolve(
                        quantityEvidence,
                        validatedUserReportedGrams: userReportedGrams,
                        validatedPackageGramsPerServing: validatedPackageServingGrams,
                        allowLowConfidenceModelEstimate: context.currentMealClarificationWasAnswered()
                    )
                } catch MealQuantityEvidenceResolutionError.missingPortionEvidence {
                    if context.currentMealClarificationWasAnswered() {
                        throw DraftError.clarificationLimitReached
                    }
                    throw DraftError.clarificationRequired(
                        field: "quantityEvidence",
                        question: "“\(ingredient.name)”大约有多少份量（例如一碗、几个或包装份数）？",
                        subject: ingredient.name
                    )
                } catch {
                    throw DraftError.invalidMeal
                }
                let portion = try portionEstimator.estimate(
                    evidence: [portionEvidence],
                    food: selectedFood
                )
                let imageEvidence: [EvidenceSnapshot] = ingredientIndex == 0
                    ? agentImageEvidence.map { evidence in
                        EvidenceSnapshot(
                            grade: evidence.kind == .barcode || evidence.kind == .nutritionLabel
                                ? .label
                                : .estimated,
                            sourceID: "agent-image:\(evidence.kind.rawValue)",
                            sourceVersion: "local-image-scan-v1",
                            summary: "本机图像线索已附加，提取文本未保存",
                            confidence: evidence.confidence
                        )
                    }
                    : []
                ingredients.append(
                    MealIngredientEstimationInput(
                        label: ingredient.name,
                        resolution: resolution,
                        portion: portion,
                        massBasis: massBasis,
                        additionalEvidence: imageEvidence
                    )
                )
            }
            let userReportedOilGrams = explicitGramsParser.exactGrams(
                in: userText,
                matching: ["食用油", "炒菜油", "橄榄油", "菜籽油", "油"]
            )
            let oilRange = try userReportedOilGrams.map(EstimateRange.point)
                ?? oilPriors.range(for: rawDish.cookingMethod)
            let oilEvidence = userReportedOilGrams.map { grams in
                EvidenceSnapshot(
                    grade: .userReported,
                    sourceID: "user-reported-oil",
                    sourceVersion: MealEstimator.algorithmVersion,
                    summary: "用户明确报告食用油 \(Int(grams.rounded()))g",
                    confidence: nil
                )
            }
            drafts.append(
                try mealEstimator.estimateDish(
                    MealDishEstimationInput(
                        name: name,
                        cookingMethod: rawDish.cookingMethod,
                        ingredients: ingredients,
                        inferredOilGrams: oilRange,
                        inferredOilEvidence: oilEvidence
                    )
                )
            )
        }

        let mealDraft = MealDraft(
            occurredAt: date,
            mealType: arguments.mealType,
            dishes: drafts,
            note: arguments.note
        )
        if let energy = mealDraft.totalNutrients?.energyKcal,
           case .needsClarification = CaloriePresentationPolicy().presentation(for: energy),
           !hasPhotoPortionEstimate,
           !context.hasIssuedMealClarification(),
           !context.currentMealClarificationWasAnswered() {
            let dishName = drafts.max { lhs, rhs in
                let lhsWidth = lhs.nutrients.energyKcal.high - lhs.nutrients.energyKcal.low
                let rhsWidth = rhs.nutrients.energyKcal.high - rhs.nutrients.energyKcal.low
                return lhsWidth < rhsWidth
            }?.name ?? "这餐"
            let clarification = ClarificationSelector().selectOne(
                from: ClarificationContext(
                    energyKcal: energy,
                    candidates: [
                        ClarificationCandidate(
                            kind: .portion,
                            prompt: "“\(dishName)”大约有多大份量？",
                            expectedEnergyRangeReduction: 0.4,
                            userEffort: 1
                        ),
                    ]
                )
            )
            if let clarification {
                throw DraftError.clarificationRequired(
                    field: "mealEnergy",
                    question: clarification.prompt,
                    subject: dishName
                )
            }
        }
        return .meal(mealDraft)
    }

    private func uniquePackageServingGrams(
        in userText: String,
        imageLabelTexts: [String],
        matching ingredientTerms: [String],
        otherIngredientNames: [String],
        parser: PackageServingGramsParser
    ) -> Double? {
        var values = Set<Double>()
        let userSentences = userText.components(separatedBy: CharacterSet(charactersIn: "。.;；\n"))
        for sentence in userSentences where mentionsAnyTerm(sentence, terms: ingredientTerms) {
            guard !otherIngredientNames.contains(where: {
                sentence.localizedCaseInsensitiveContains($0)
            }) else { continue }
            if let grams = parser.gramsPerServing(in: sentence) { values.insert(grams) }
        }
        for labelText in imageLabelTexts where mentionsAnyTerm(labelText, terms: ingredientTerms) {
            guard !otherIngredientNames.contains(where: {
                labelText.localizedCaseInsensitiveContains($0)
            }) else { continue }
            if let grams = parser.gramsPerServing(in: labelText) { values.insert(grams) }
        }
        guard values.count == 1 else { return nil }
        return values.first
    }

    private func mentionsAnyTerm(_ text: String, terms: [String]) -> Bool {
        terms.contains { term in
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            return !normalized.isEmpty && text.localizedCaseInsensitiveContains(normalized)
        }
    }
}

private struct LogMealArguments: Decodable {
    let mealType: String
    let occurredAt: String?
    let dishes: [Dish]
    let note: String?

    struct Dish: Decodable {
        let dishName: String
        let cookingMethod: String
        let ingredients: [Ingredient]
        let lowConfidence: Bool
    }

    struct Ingredient: Decodable {
        let name: String
        let quantityEvidence: MealQuantityEvidence
        let preparation: String?
        let massBasis: String?
    }
}
