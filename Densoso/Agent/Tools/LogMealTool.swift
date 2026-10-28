import DensosoDomain
import Foundation

struct LogMealTool: ConfirmationRequiredTool {
    let mealPortionPriorRepository: (any MealPortionPriorRepository)?
    private let recipePriorCatalogOverride: RecipePriorCatalog?

    init(
        mealPortionPriorRepository: (any MealPortionPriorRepository)? = nil,
        recipePriorCatalog: RecipePriorCatalog? = nil
    ) {
        self.mealPortionPriorRepository = mealPortionPriorRepository
        self.recipePriorCatalogOverride = recipePriorCatalog
    }

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
                            "recipePriorID": .anyOf([
                                .string(minimumLength: 1, maximumLength: 240), .null,
                            ]),
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
        let packageLabelTexts = agentImageEvidence
            .filter { $0.kind == .nutritionLabel }
            .map(\.value)
        let allIngredientNames = arguments.dishes.flatMap { $0.ingredients.map(\.name) }
        let recipeCatalog: RecipePriorCatalog?
        if arguments.dishes.contains(where: { $0.recipePriorID != nil }) {
            do {
                recipeCatalog = try recipePriorCatalogOverride ?? RecipePriorCatalog.bundled()
            } catch {
                throw DraftError.invalidMeal
            }
        } else {
            recipeCatalog = nil
        }
        var firstOccurrenceByFoodIdentity: [String: (dishIndex: Int, dishName: String)] = [:]
        var drafts: [MealDishDraft] = []
        for (dishIndex, rawDish) in arguments.dishes.enumerated() {
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

            let recipePrior: RecipePriorRecord?
            if let recipePriorID = rawDish.recipePriorID {
                guard let recipeCatalog,
                      let record = recipeCatalog.exactRecord(dishName: name, id: recipePriorID) else {
                    throw DraftError.invalidMeal
                }
                recipePrior = record
            } else {
                recipePrior = nil
            }
            let resolvedCookingMethod = resolvedCookingMethod(
                modelMethod: rawDish.cookingMethod,
                recipePrior: recipePrior
            )
            let cookingMethodEvidence = makeCookingMethodEvidence(
                modelMethod: rawDish.cookingMethod,
                resolvedMethod: resolvedCookingMethod,
                recipePrior: recipePrior,
                lowConfidence: rawDish.lowConfidence,
                modelProvenance: context.currentMealModelProvenance()
            )
            let personalDishPrior = try await mealPortionPriorRepository?.dishPrior(
                named: name,
                cookingMethod: resolvedCookingMethod == "unknown" ? nil : resolvedCookingMethod
            )
            let recipeEvidence = recipePrior.map { [recipePriorEvidence($0)] } ?? []

            var ingredients: [MealIngredientEstimationInput] = []
            var hasExplicitOilIngredient = false
            for (ingredientIndex, ingredient) in rawDish.ingredients.enumerated() {
                let preparation: FoodPreparation
                if let rawPreparation = ingredient.preparation {
                    guard let parsedPreparation = FoodPreparation(rawValue: rawPreparation) else {
                        throw DraftError.invalidMeal
                    }
                    preparation = parsedPreparation
                } else {
                    preparation = .unknown
                }
                let requestedMassBasis: FoodMassBasis?
                if let rawMassBasis = ingredient.massBasis {
                    guard let parsedMassBasis = FoodMassBasis(rawValue: rawMassBasis) else {
                        throw DraftError.invalidMeal
                    }
                    requestedMassBasis = parsedMassBasis
                } else {
                    requestedMassBasis = nil
                }
                let confirmedHistory = await context.confirmedFoodIDs(matching: ingredient.name)
                let resolution = resolver.resolve(
                    FoodResolutionV2Query(
                        label: ingredient.name,
                        preparation: preparation,
                        massBasis: requestedMassBasis,
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
                guard let massBasis = requestedMassBasis
                    ?? Self.sourceBackedMassBasis(for: selectedFood.entry) else {
                    throw DraftError.clarificationRequired(
                        field: "massBasis",
                        question: "“\(ingredient.name)”大约多少克？重量按生重、熟重，还是包含不可食部分的购买重量？",
                        subject: ingredient.name
                    )
                }
                if FoodResolver.normalize(selectedFood.entry.category).contains("oil")
                    || selectedFood.entry.name.contains("油") {
                    hasExplicitOilIngredient = true
                }
                let ingredientTerms = [ingredient.name, selectedFood.entry.name] + selectedFood.entry.aliases
                let localFoodIDKeys = selectedFood.entry.localFoodID.map { ["id:\($0)"] } ?? []
                let normalizedTermKeys = ingredientTerms
                    .map { "term:\(FoodResolver.normalize($0))" }
                    .filter { $0 != "term:" }
                let foodIdentityKeys = Array(Set(localFoodIDKeys + normalizedTermKeys)).sorted()
                let firstOccurrence = foodIdentityKeys
                    .compactMap { firstOccurrenceByFoodIdentity[$0] }
                    .first { $0.dishIndex != dishIndex }
                if let firstOccurrence,
                   !userExplicitlySeparatesRepeatedIngredient(in: userText, matching: ingredientTerms) {
                    let question: String
                    if userExplicitlySharesRepeatedIngredient(in: userText, matching: ingredientTerms) {
                        question = "你说明“\(ingredient.name)”是同一份，但草稿把它放进了“\(firstOccurrence.dishName)”和“\(name)”两道菜。请修正草稿，只保留一次并说明合并后的份量。"
                    } else {
                        question = "“\(ingredient.name)”同时出现在“\(firstOccurrence.dishName)”和“\(name)”中。它们是不同份量，还是同一份食材被重复拆解？请说明是否分别计量，避免重复计入。"
                    }
                    throw DraftError.clarificationRequired(
                        field: "mealEnergy",
                        question: question,
                        subject: ingredient.name
                    )
                }
                for foodIdentityKey in foodIdentityKeys where firstOccurrenceByFoodIdentity[foodIdentityKey] == nil {
                    firstOccurrenceByFoodIdentity[foodIdentityKey] = (dishIndex, name)
                }
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
                let correctionPriorEvidence = MealPortionPriorCorrection.parse(
                    userText: userText,
                    matching: ingredientTerms,
                    gramsParser: explicitGramsParser
                )
                let recipeIngredient = recipePrior.flatMap {
                    matchingRecipeIngredient(named: ingredient.name, in: $0)
                }
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
                } else if ingredient.quantityEvidence.kind == .unknown,
                          ingredient.quantityEvidence.value == nil,
                          let recipeIngredient,
                          let recipePrior,
                          !recipeIngredient.isOptional,
                          !recipeIngredient.isAlternative,
                          let sourceQuantity = recipePriorGramQuantity(
                            recipeIngredient,
                            servingsSourceText: recipePrior.servingsSourceText
                          ) {
                    // Only use a recipe-batch quantity when its source states a
                    // serving count. Divide by that count, then keep the meal amount
                    // as an uncertain model estimate rather than measured grams.
                    quantityEvidence = MealQuantityEvidence(
                        kind: .unknown,
                        value: sourceQuantity.likelyGrams,
                        unit: "g"
                    )
                } else {
                    quantityEvidence = ingredient.quantityEvidence
                }
                let dishPriorIngredient: PersonalMealDishIngredientPrior?
                if ingredient.quantityEvidence.kind == .unknown,
                   ingredient.quantityEvidence.value == nil,
                   userReportedGrams == nil,
                   validatedPackageServingGrams == nil,
                   let personalDishPrior,
                   let priorIngredient = personalDishPrior.ingredient(
                    foodID: selectedFood.entry.localFoodID,
                    name: selectedFood.entry.name
                   ),
                   priorIngredient.massBasis == nil
                    || priorIngredient.massBasis == Self.sourceBackedMassBasis(for: selectedFood.entry) {
                    dishPriorIngredient = priorIngredient
                } else {
                    dishPriorIngredient = nil
                }
                let personalPrior: HouseholdPortionPrior?
                if (quantityEvidence.kind == .household || quantityEvidence.kind == .count),
                   let quantityUnit = quantityEvidence.unit,
                   MealPortionPriorCorrection.normalizeSupportedUnit(quantityUnit) != nil {
                    personalPrior = try await mealPortionPriorRepository?.prior(
                        foodID: selectedFood.entry.localFoodID,
                        foodName: selectedFood.entry.name,
                        unit: quantityUnit
                    )
                } else {
                    personalPrior = nil
                }
                let portionEvidence: PortionEvidence
                if let dishPriorIngredient {
                    portionEvidence = .personalDishPrior(
                        lowGrams: dishPriorIngredient.lowGrams,
                        likelyGrams: dishPriorIngredient.likelyGrams,
                        highGrams: dishPriorIngredient.highGrams
                    )
                } else {
                    do {
                        portionEvidence = try quantityResolver.resolve(
                            quantityEvidence,
                            validatedUserReportedGrams: userReportedGrams,
                            validatedPackageGramsPerServing: validatedPackageServingGrams,
                            personalPrior: personalPrior,
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
                }
                let personalPriorUsageEvidence: EvidenceSnapshot?
                if let personalPrior,
                   case .household(let resolvedPrior, let count) = portionEvidence,
                   resolvedPrior == personalPrior,
                   let usage = MealPortionPriorUsage(prior: resolvedPrior, count: count) {
                    personalPriorUsageEvidence = usage.evidenceSnapshot
                } else {
                    personalPriorUsageEvidence = nil
                }
                let personalDishPriorUsageEvidence = personalDishPrior.flatMap { prior in
                    dishPriorIngredient.flatMap { ingredient in
                        PersonalMealDishPriorUsage(prior: prior, ingredient: ingredient)?.evidenceSnapshot
                    }
                }
                let portion = try portionEstimator.estimate(
                    evidence: [portionEvidence],
                    food: selectedFood
                )
                var imageEvidence: [EvidenceSnapshot] = ingredientIndex == 0
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
                if let correctionPriorEvidence {
                    imageEvidence.append(correctionPriorEvidence.evidenceSnapshot)
                }
                if let userReportedGrams,
                   let userPortionEvidence = PersonalMealDishPriorUserPortionEvidence.evidenceSnapshot(
                    grams: userReportedGrams
                   ) {
                    imageEvidence.append(userPortionEvidence)
                }
                if let personalPriorUsageEvidence {
                    imageEvidence.append(personalPriorUsageEvidence)
                }
                if let personalDishPriorUsageEvidence {
                    imageEvidence.append(personalDishPriorUsageEvidence)
                }
                if let recipeIngredient, let recipePrior {
                    imageEvidence.append(recipeIngredientEvidence(
                        recipeIngredient,
                        record: recipePrior,
                        preparation: ingredient.preparation,
                        massBasis: ingredient.massBasis
                    ))
                }
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
                ?? oilPriors.range(for: resolvedCookingMethod)
            let oilEvidence = userReportedOilGrams.map { grams in
                EvidenceSnapshot(
                    grade: .userReported,
                    sourceID: "user-reported-oil",
                    sourceVersion: MealEstimator.algorithmVersion,
                    summary: "用户明确报告食用油 \(Int(grams.rounded()))g",
                    confidence: nil
                )
            }
            var recipeOilRetention: EstimateRange?
            var recipeOilRetentionEvidence: EvidenceSnapshot?
            if !hasExplicitOilIngredient,
               let recipePrior,
               let sourceQuantity = recipePriorGramQuantity(
                    recipePrior.oilRetention,
                    servingsSourceText: recipePrior.servingsSourceText
               ) {
                let sourcePortionEvidence = try? quantityResolver.resolve(
                    MealQuantityEvidence(
                        kind: .exactGrams,
                        value: sourceQuantity.likelyGrams,
                        unit: "g"
                    )
                )
                if let sourcePortionEvidence,
                   let portion = try? portionEstimator.estimate(evidence: [sourcePortionEvidence]),
                   let range = try? EstimateRange(
                       low: portion.lowGrams,
                       likely: portion.likelyGrams,
                       high: portion.highGrams
                   ) {
                    recipeOilRetention = range
                    recipeOilRetentionEvidence = EvidenceSnapshot(
                        grade: .moderate,
                        sourceID: "recipe-prior:\(recipePrior.id):oil-retention",
                        sourceVersion: recipePrior.sourceVersion,
                        summary: "菜谱来源的油保留量作为宽区间估算先验：\(quantitySummary(recipePrior.oilRetention))；未当作本餐实测油量",
                        confidence: nil
                    )
                }
            }
            drafts.append(
                try PerformanceSignposts.measure("Meal.DeterministicEstimate") {
                    try mealEstimator.estimateDish(
                        MealDishEstimationInput(
                            name: name,
                            cookingMethod: resolvedCookingMethod,
                            ingredients: ingredients,
                            inferredOilGrams: oilRange,
                            inferredOilEvidence: oilEvidence,
                            recipeOilRetentionGrams: recipeOilRetention,
                            recipeOilRetentionEvidence: recipeOilRetentionEvidence,
                            recipePriorEvidence: recipeEvidence,
                            cookingMethodEvidence: cookingMethodEvidence,
                            suppressInferredOil: recipeOilRetention != nil
                        )
                    )
                }
            )
        }

        let unscaledMealDraft = MealDraft(
            occurredAt: date,
            mealType: arguments.mealType,
            dishes: drafts,
            note: arguments.note
        )
        let mealDraft: MealDraft
        let isConsumedFractionClarificationAnswer = context.currentMealPriorClarificationField() == "consumedFraction"
        switch consumedFractionResolution(in: userText, dishes: arguments.dishes) {
        case .resolved(let consumedFractionEvidence):
            mealDraft = try unscaledMealDraft.applyingConsumedFraction(consumedFractionEvidence)
        case .unresolved:
            guard !isConsumedFractionClarificationAnswer else {
                throw DraftError.clarificationLimitReached
            }
            throw DraftError.clarificationRequired(
                field: "consumedFraction",
                question: "你提到的摄入比例还不明确。请说明比例是指整餐还是某一道菜，并告诉我整餐实际吃下的份量；确认前我不会按全份计入。",
                subject: "整餐摄入比例"
            )
        case .none:
            guard !isConsumedFractionClarificationAnswer else {
                // The one consumed-fraction clarification was answered without a usable whole-meal ratio.
                throw DraftError.clarificationLimitReached
            }
            mealDraft = unscaledMealDraft
        }
        if let energy = mealDraft.totalNutrients?.energyKcal,
           case .needsClarification = CaloriePresentationPolicy().presentation(for: energy),
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

    private func resolvedCookingMethod(
        modelMethod: String,
        recipePrior: RecipePriorRecord?
    ) -> String {
        guard modelMethod == "unknown",
              let recipeMethod = recipePrior?.cookingMethod,
              ["steam", "boil", "coldDress", "stirFry", "braise", "dryFry", "deepFry", "roast", "stew"]
                .contains(recipeMethod) else {
            return modelMethod
        }
        return recipeMethod
    }

    private func makeCookingMethodEvidence(
        modelMethod: String,
        resolvedMethod: String,
        recipePrior: RecipePriorRecord?,
        lowConfidence: Bool,
        modelProvenance: AgentMealModelProvenance?
    ) -> EvidenceSnapshot? {
        if modelMethod != "unknown" {
            let confidenceNote = lowConfidence ? "（识别标记为低置信度）" : ""
            let providerLabel: String
            let modelLabel: String
            let sourceVersion: String
            let requestIdentity: String
            let sourceID: String
            if let modelProvenance {
                providerLabel = providerName(modelProvenance.selectedProvider)
                let reportedModel = sanitizedModelIdentifier(modelProvenance.reportedModel)
                let configuredModel = sanitizedModelIdentifier(modelProvenance.configuredModel)
                if let reportedModel {
                    modelLabel = "\(reportedModel)（Provider 返回）"
                    sourceVersion = "reported:\(reportedModel)"
                } else if let configuredModel {
                    modelLabel = "\(configuredModel)（配置模型；本轮未返回 usage）"
                    sourceVersion = "configured:\(configuredModel)"
                } else {
                    modelLabel = "模型标识不可用"
                    sourceVersion = "unreported"
                }
                requestIdentity = "providerRequestID=unavailable; Agent request correlation=\(modelProvenance.agentRequestID.uuidString)"
                sourceID = "meal-model-cooking-method:\(modelProvenance.selectedProvider.rawValue)"
            } else {
                providerLabel = "unavailable"
                modelLabel = "模型标识不可用"
                sourceVersion = "unreported"
                requestIdentity = "provider request ID unavailable; Agent request correlation unavailable"
                sourceID = "meal-model-cooking-method:unattributed"
            }
            return EvidenceSnapshot(
                grade: .estimated,
                sourceID: sourceID,
                sourceVersion: sourceVersion,
                summary: "模型识别的烹饪方法：\(cookingMethodLabel(resolvedMethod))\(confidenceNote)；未由用户或菜谱来源验证；provider=\(providerLabel)；model=\(modelLabel)；\(requestIdentity)；toolVersion=log-meal-tool-v1；estimatorVersion=\(MealEstimator.algorithmVersion)",
                confidence: nil
            )
        }

        guard let recipePrior,
              resolvedMethod != "unknown",
              recipePrior.cookingMethod == resolvedMethod else {
            return nil
        }
        let grade: EvidenceGrade
        switch recipePrior.confidenceGrade.lowercased() {
        case "strong": grade = .strong
        case "moderate": grade = .moderate
        case "weak": grade = .weak
        default: grade = .estimated
        }
        return EvidenceSnapshot(
            grade: grade,
            sourceID: "recipe-prior:\(recipePrior.sourceID):\(recipePrior.sourceRecordID):cooking-method",
            sourceVersion: recipePrior.sourceVersion,
            summary: "来源菜谱提供烹饪方法：\(cookingMethodLabel(resolvedMethod))；作为估算先验，非本餐实测",
            confidence: nil
        )
    }

    private func providerName(_ provider: ProviderID) -> String {
        switch provider {
        case .deepSeek: "DeepSeek"
        case .qwen: "Qwen"
        }
    }

    private func sanitizedModelIdentifier(_ model: String?) -> String? {
        guard let model else { return nil }
        let normalized = model
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(96))
    }

    private func cookingMethodLabel(_ method: String) -> String {
        switch method {
        case "steam": "蒸"
        case "boil": "煮"
        case "coldDress": "凉拌"
        case "stirFry": "炒"
        case "braise": "焖烧"
        case "dryFry": "干煸"
        case "deepFry": "油炸"
        case "roast": "烤"
        case "stew": "炖"
        default: "未识别"
        }
    }

    private func matchingRecipeIngredient(
        named name: String,
        in recipe: RecipePriorRecord
    ) -> RecipeIngredientPrior? {
        let normalizedName = FoodResolver.normalize(name)
        guard normalizedName.count >= 2 else { return nil }
        let candidates = recipe.ingredients.filter { ingredient in
            let sourceName = FoodResolver.normalize(ingredient.sourceName)
            return sourceName == normalizedName
                || sourceName.contains(normalizedName)
                || normalizedName.contains(sourceName)
        }
        return candidates.count == 1 ? candidates.first : nil
    }

    private func recipePriorGramQuantity(
        _ ingredient: RecipeIngredientPrior,
        servingsSourceText: String?
    ) -> RecipeGramQuantity? {
        recipePriorGramQuantity(
            ingredient.quantityEvidence,
            servingsSourceText: servingsSourceText
        )
    }

    private func recipePriorGramQuantity(
        _ quantity: RecipePriorQuantityEvidence,
        servingsSourceText: String?
    ) -> RecipeGramQuantity? {
        guard ["sourceQuantity", "sourceRange", "formula"].contains(quantity.kind),
              let unit = quantity.unit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["g", "gram", "grams", "克", "公克"].contains(unit),
              let low = quantity.value,
              low.isFinite, low > 0, low <= 5_000 else {
            return nil
        }
        let high = quantity.upperValue ?? low
        guard high.isFinite, high >= low, high <= 5_000 else { return nil }
        let batchQuantity = RecipeGramQuantity(
            lowGrams: low,
            likelyGrams: (low + high) / 2,
            highGrams: high
        )
        guard let servings = recipeServingQuantity(servingsSourceText) else { return nil }
        return RecipeGramQuantity(
            lowGrams: batchQuantity.lowGrams / servings.high,
            likelyGrams: batchQuantity.likelyGrams / servings.likely,
            highGrams: batchQuantity.highGrams / servings.low
        )
    }

    private func recipeServingQuantity(_ sourceText: String?) -> RecipeServingQuantity? {
        guard let sourceText, !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let numericPattern = try? NSRegularExpression(
                pattern: #"([0-9]+(?:\.[0-9]+)?)(?:\s*(?:-|–|~|至|到)\s*([0-9]+(?:\.[0-9]+)?))?\s*(?:个)?人"#
              ) else {
            return nil
        }
        guard !sourceText.contains("或"),
              !sourceText.localizedCaseInsensitiveContains(" or "),
              let ambiguousChinesePattern = try? NSRegularExpression(
                pattern: #"[一二两三四五六七八九][一二两三四五六七八九]\s*(?:个)?人"#
              ) else {
            return nil
        }
        let fullRange = NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
        guard ambiguousChinesePattern.firstMatch(in: sourceText, range: fullRange) == nil else {
            return nil
        }
        if let match = numericPattern.firstMatch(in: sourceText, range: fullRange),
           let lowerRange = Range(match.range(at: 1), in: sourceText),
           let lower = Double(sourceText[lowerRange]) {
            let upper: Double
            if match.range(at: 2).location == NSNotFound {
                upper = lower
            } else if let upperRange = Range(match.range(at: 2), in: sourceText),
                      let parsedUpper = Double(sourceText[upperRange]) {
                upper = parsedUpper
            } else {
                return nil
            }
            guard lower > 0, upper >= lower, upper <= 20 else {
                return nil
            }
            return RecipeServingQuantity(low: lower, likely: (lower + upper) / 2, high: upper)
        }

        let chineseDigits: [Character: Double] = [
            "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
        ]
        guard let chinesePattern = try? NSRegularExpression(
            pattern: #"([一二两三四五六七八九十]+)(?:\s*(?:-|–|~|至|到)\s*([一二两三四五六七八九十]+))?\s*(?:个)?人"#
        ), let match = chinesePattern.firstMatch(in: sourceText, range: fullRange),
           let lowerRange = Range(match.range(at: 1), in: sourceText),
           let lower = Self.chineseServingNumber(String(sourceText[lowerRange]), digits: chineseDigits) else {
            return nil
        }
        let upper: Double
        if match.range(at: 2).location == NSNotFound {
            upper = lower
        } else if let upperRange = Range(match.range(at: 2), in: sourceText),
                  let parsedUpper = Self.chineseServingNumber(String(sourceText[upperRange]), digits: chineseDigits) {
            upper = parsedUpper
        } else {
            return nil
        }
        guard lower > 0, upper >= lower, upper <= 20 else {
            return nil
        }
        return RecipeServingQuantity(low: lower, likely: (lower + upper) / 2, high: upper)
    }

    private static func chineseServingNumber(
        _ text: String,
        digits: [Character: Double]
    ) -> Double? {
        if text == "十" { return 10 }
        guard text.count <= 2 else { return nil }
        let characters = Array(text)
        if characters.count == 1 { return digits[characters[0]] }
        guard let first = digits[characters[0]], let second = digits[characters[1]] else { return nil }
        if characters[0] == "十" { return 10 + second }
        if characters[1] == "十" { return first * 10 }
        return nil
    }

    private static func sourceBackedMassBasis(for entry: FoodCatalogEntry) -> FoodMassBasis? {
        guard entry.licenseStatus == "verified",
              let sourceID = entry.sourceID, !sourceID.isEmpty,
              let sourceRecordID = entry.sourceRecordID, !sourceRecordID.isEmpty,
              !entry.sourceVersion.isEmpty,
              let rawMassBasis = entry.massBasis else {
            return nil
        }
        return FoodMassBasis(rawValue: rawMassBasis)
    }

    private func recipePriorEvidence(_ record: RecipePriorRecord) -> EvidenceSnapshot {
        let grade: EvidenceGrade
        switch record.confidenceGrade.lowercased() {
        case "strong": grade = .strong
        case "moderate": grade = .moderate
        case "weak": grade = .weak
        default: grade = .estimated
        }
        let households = record.householdMeasures.isEmpty
            ? "none"
            : record.householdMeasures.joined(separator: ",")
        return EvidenceSnapshot(
            grade: grade,
            sourceID: "recipe-prior:\(record.sourceID):\(record.sourceRecordID)",
            sourceVersion: record.sourceVersion,
            summary: "Recipe prior id=\(record.id); category=\(record.category); cookingMethod=\(record.cookingMethod); cookingMethodEvidence=\(record.cookingMethodEvidence); recordSHA256=\(record.sourceRecordSHA256); license=\(record.licenseSPDX); licenseStatus=\(record.licenseStatus); confidence=\(record.confidenceGrade); servings=\(record.servingsSourceText ?? "not specified"); cookedYield=\(quantitySummary(record.cookedYieldEvidence)); householdMeasures=\(households); oilRetention=\(quantitySummary(record.oilRetention)); dataRole=recipe-prior; nutritionAuthority=false; not a user-measured portion"
        )
    }

    private func recipeIngredientEvidence(
        _ ingredient: RecipeIngredientPrior,
        record: RecipePriorRecord,
        preparation: String?,
        massBasis: String?
    ) -> EvidenceSnapshot {
        let quantity = ingredient.quantityEvidence
        let amount = quantitySummary(quantity)
        return EvidenceSnapshot(
            grade: .moderate,
            sourceID: "recipe-prior:\(record.id):ingredient:\(FoodResolver.normalize(ingredient.sourceName))",
            sourceVersion: record.sourceVersion,
            summary: "Source ingredient \(ingredient.sourceName); quantity=\(amount); optional=\(ingredient.isOptional); alternative=\(ingredient.isAlternative); model preparation=\(preparation ?? "unknown"); model massBasis=\(massBasis ?? "unknown"); source quantity is a recipe prior, not this meal's measured grams"
        )
    }

    private func quantitySummary(_ quantity: RecipePriorQuantityEvidence) -> String {
        let sourceText = quantity.sourceText ?? "not specified"
        let range: String
        if let value = quantity.value, let upperValue = quantity.upperValue {
            range = "; values=\(value)-\(upperValue) \(quantity.unit ?? "")"
        } else if let value = quantity.value {
            range = "; value=\(value) \(quantity.unit ?? "")"
        } else {
            range = ""
        }
        return "\(quantity.kind): \(sourceText)\(range)"
    }

    private enum ConsumedFractionResolution {
        case none
        case resolved(ConsumedFractionEvidence)
        case unresolved
    }

    private func consumedFractionResolution(
        in userText: String,
        dishes: [LogMealArguments.Dish]
    ) -> ConsumedFractionResolution {
        let consumptionMarkers = [
            "吃了", "吃掉", "没吃", "没有吃", "未吃", "不吃", "摄入", "ate", "eat", "eaten", "consumed",
        ]
        let wholeMealMarkers = [
            "这餐", "这顿", "这一餐", "这顿饭", "本餐", "整餐", "整顿饭", "全部菜", "全部食材",
            "所有菜", "每道菜", "每一道菜",
            "entiremeal", "wholemeal", "allmeals", "alldishes",
        ]
        let allDishMarkers = [
            "全部菜", "全部食材", "所有菜", "每道菜", "每一道菜", "都吃", "allingredients", "alldishes",
        ]
        let distinctIngredientTerms = Set(dishes.flatMap { dish in
            dish.ingredients.map { FoodResolver.normalize($0.name) }
        }.filter { !$0.isEmpty })
        let nonExactOrNegatedMarkers = [
            "不是", "并非", "没有", "没吃", "未吃", "不吃", "不止", "超过", "多于", "至少", "至多", "不到", "少于",
            "大约", "大概", "差不多", "左右", "约", "可能", "也许", "估计", "不太确定",
            "not", "didnt", "didnot", "dontknow", "not sure", "unsure", "maybe", "possibly", "about", "roughly", "approx",
        ]
        let clauses = userText.components(separatedBy: CharacterSet(charactersIn: "，,。;；\n"))
        var fractions: [Double] = []
        var hasUnresolvedFractionClaim = false
        for clause in clauses {
            let normalizedClause = FoodResolver.normalize(clause)
            let containsConsumptionMarker = consumptionMarkers.contains {
                normalizedClause.contains($0)
            }
            let containsWholeMealMarker = wholeMealMarkers.contains {
                normalizedClause.contains(FoodResolver.normalize($0))
            }
            let containsKnownFoodName = dishes.contains { dish in
                let names = [dish.dishName] + dish.ingredients.map(\.name)
                return names.contains { name in
                    let normalizedName = FoodResolver.normalize(name)
                    return normalizedName.count >= 2 && normalizedClause.contains(normalizedName)
                }
            }
            let quantityContextMarkers = ["包装", "每份", "克", "公克", "份量", "配方", "食谱"]
            let isQuantityContext = quantityContextMarkers.contains {
                normalizedClause.contains(FoodResolver.normalize($0))
            }
            guard containsConsumptionMarker
                    || (containsWholeMealMarker && !isQuantityContext)
                    || (containsKnownFoodName && !isQuantityContext) else { continue }
            guard containsFractionExpression(in: clause) else { continue }
            guard !nonExactOrNegatedMarkers.contains(where: { normalizedClause.contains($0) }) else {
                hasUnresolvedFractionClaim = true
                continue
            }
            guard let fraction = explicitFractionValue(in: clause) else {
                hasUnresolvedFractionClaim = true
                continue
            }
            let explicitlyCoversAllDishes = containsWholeMealMarker && allDishMarkers.contains {
                normalizedClause.contains(FoodResolver.normalize($0))
            }
            let namedDishTerms = Set(dishes.compactMap { dish -> String? in
                let normalizedName = FoodResolver.normalize(dish.dishName)
                return normalizedName.count >= 2 && normalizedClause.contains(normalizedName)
                    ? normalizedName
                    : nil
            })
            let namesWholeDishInClause = namedDishTerms.contains { dishTerm in
                distinctIngredientTerms.count == 1 || !distinctIngredientTerms.contains(dishTerm)
            }
            let namesIngredientInClause = distinctIngredientTerms.contains { term in
                term.count >= 2 && normalizedClause.contains(term)
            }
            let scopeIsWholeMeal: Bool
            if explicitlyCoversAllDishes {
                scopeIsWholeMeal = true
            } else if namesWholeDishInClause {
                scopeIsWholeMeal = dishes.count == 1
            } else if namesIngredientInClause {
                scopeIsWholeMeal = dishes.count == 1 && distinctIngredientTerms.count == 1
            } else {
                scopeIsWholeMeal = dishes.count == 1
                    || wholeMealMarkers.contains { normalizedClause.contains($0) }
            }
            if !scopeIsWholeMeal {
                hasUnresolvedFractionClaim = true
                continue
            }
            fractions.append(fraction)
        }
        guard !hasUnresolvedFractionClaim else { return .unresolved }
        guard let firstFraction = fractions.first else { return .none }
        guard fractions.allSatisfy({ abs($0 - firstFraction) < 0.000_001 }) else {
            return .unresolved
        }
        guard let evidence = ConsumedFractionEvidence(fraction: firstFraction) else {
            return .unresolved
        }
        return .resolved(evidence)
    }

    private func containsFractionExpression(in text: String) -> Bool {
        let lowercasedText = text.lowercased()
        if [
            "四分之三", "三分之二", "三分之一", "四分之一", "二分之一", "一半", "半份", "half",
        ].contains(where: { lowercasedText.contains($0) }) {
            return true
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let patterns = [#"[0-9]+(?:\.[0-9]+)?\s*%"#, #"[0-9]+\s*[/／]\s*[0-9]+"#]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            return regex.firstMatch(in: text, range: range) != nil
        }
    }

    private func explicitFractionValue(in text: String) -> Double? {
        var candidates: [Double] = []
        let percentRegex = try? NSRegularExpression(
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%"#
        )
        let ratioRegex = try? NSRegularExpression(
            pattern: #"([0-9]+)\s*[/／]\s*([0-9]+)"#
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let percentRegex {
            for match in percentRegex.matches(in: text, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: text),
                      let percent = Double(text[valueRange]) else { continue }
                candidates.append(percent / 100)
            }
        }
        if let ratioRegex {
            for match in ratioRegex.matches(in: text, range: range) {
                guard let numeratorRange = Range(match.range(at: 1), in: text),
                      let denominatorRange = Range(match.range(at: 2), in: text),
                      let numerator = Double(text[numeratorRange]),
                      let denominator = Double(text[denominatorRange]),
                      denominator > 0 else { continue }
                candidates.append(numerator / denominator)
            }
        }
        let chineseFractions: [(String, Double)] = [
            ("四分之三", 0.75), ("三分之二", 2.0 / 3.0), ("三分之一", 1.0 / 3.0),
            ("四分之一", 0.25), ("二分之一", 0.5), ("一半", 0.5), ("半份", 0.5),
        ]
        let lowercasedText = text.lowercased()
        for (phrase, value) in chineseFractions where lowercasedText.contains(phrase) {
            candidates.append(value)
        }
        if lowercasedText.contains("half") { candidates.append(0.5) }
        guard candidates.count == 1,
              candidates[0].isFinite,
              candidates[0] > 0,
              candidates[0] <= 1 else {
            return nil
        }
        return candidates[0]
    }

    private func userExplicitlySeparatesRepeatedIngredient(
        in userText: String,
        matching ingredientTerms: [String]
    ) -> Bool {
        let sharedPortionMarkers = [
            "同一份", "同一碗", "同一块", "同一批", "重复计量", "只算一次", "sameportion", "duplicate",
        ]
        let negatedSharedPortionMarkers = [
            "不是同一份", "并非同一份", "不是同一碗", "不是重复", "不算重复", "notthesame", "notduplicate",
        ]
        let separateOccurrenceMarkers = [
            "分别各有", "每道菜各", "每道菜都有", "各自有", "各有一份", "各自一份",
            "分别计量", "不同份量", "每道菜分别有", "每份各有",
            "each dish", "each serving", "separate servings", "different portions",
        ]
        let notSeparateMarkers = [
            "不是分别", "并非分别", "不分别", "不是各自", "不各自", "不是各有", "不各有",
            "notseparately", "notseparate", "noteachdish",
        ]
        return userText
            .components(separatedBy: CharacterSet(charactersIn: "，,。;；\n"))
            .contains { clause in
                let normalizedClause = FoodResolver.normalize(clause)
                let mentionsIngredient = ingredientTerms.contains { term in
                    let normalizedTerm = FoodResolver.normalize(term)
                    return !normalizedTerm.isEmpty && normalizedClause.contains(normalizedTerm)
                }
                guard mentionsIngredient,
                      !notSeparateMarkers.contains(where: { normalizedClause.contains($0) }) else {
                    return false
                }
                let deniesSharedPortion = negatedSharedPortionMarkers.contains {
                    normalizedClause.contains($0)
                }
                if !deniesSharedPortion,
                   sharedPortionMarkers.contains(where: { normalizedClause.contains($0) }) {
                    return false
                }
                return separateOccurrenceMarkers.contains { marker in
                    normalizedClause.contains(FoodResolver.normalize(marker))
                }
        }
    }

    private func userExplicitlySharesRepeatedIngredient(
        in userText: String,
        matching ingredientTerms: [String]
    ) -> Bool {
        let sharedPortionMarkers = [
            "同一份", "同一碗", "同一块", "同一批", "重复计量", "只算一次", "sameportion", "duplicate",
        ]
        let negatedSharedPortionMarkers = [
            "不是同一份", "并非同一份", "不是同一碗", "不是重复", "不算重复", "notthesame", "notduplicate",
        ]
        return userText
            .components(separatedBy: CharacterSet(charactersIn: "，,。;；\n"))
            .contains { clause in
                let normalizedClause = FoodResolver.normalize(clause)
                let mentionsIngredient = ingredientTerms.contains { term in
                    let normalizedTerm = FoodResolver.normalize(term)
                    return !normalizedTerm.isEmpty && normalizedClause.contains(normalizedTerm)
                }
                guard mentionsIngredient,
                      !negatedSharedPortionMarkers.contains(where: { normalizedClause.contains($0) }) else {
                    return false
                }
                return sharedPortionMarkers.contains { normalizedClause.contains($0) }
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
        let recipePriorID: String?
    }

    struct Ingredient: Decodable {
        let name: String
        let quantityEvidence: MealQuantityEvidence
        let preparation: String?
        let massBasis: String?
    }
}

private struct RecipeGramQuantity {
    let lowGrams: Double
    let likelyGrams: Double
    let highGrams: Double
}

private struct RecipeServingQuantity {
    let low: Double
    let likely: Double
    let high: Double
}
