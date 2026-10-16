import DensosoDomain
import Foundation

struct MealVisionQualityGate: Equatable, Sendable {
    let exactAliasAccuracy: Double
    let rawCookedAccuracy: Double
    let top1Accuracy: Double
    let top3Accuracy: Double
    let portionCoverage: Double

    var allowsOpenPhoto: Bool {
        exactAliasAccuracy == 1
            && rawCookedAccuracy == 1
            && top1Accuracy >= 0.80
            && top3Accuracy >= 0.90
            && portionCoverage >= 0.80
    }

    static let unavailable = MealVisionQualityGate(
        exactAliasAccuracy: 0,
        rawCookedAccuracy: 0,
        top1Accuracy: 0,
        top3Accuracy: 0,
        portionCoverage: 0
    )

    static let syntheticContractV1 = MealVisionQualityGate(
        exactAliasAccuracy: 1,
        rawCookedAccuracy: 1,
        top1Accuracy: 1,
        top3Accuracy: 1,
        portionCoverage: 1
    )
}

struct MealCaptureReview: Identifiable, Sendable {
    enum Route: String, Equatable, Sendable {
        case packagedBarcode
        case nutritionLabel
        case qwenVision
        case manualDescription
    }

    let id: UUID
    let route: Route
    let evidence: [MealEvidence]
    let label: String
    let resolution: FoodResolution?
    let portion: PortionEstimate?
    let cookingMethod: String?
    let inferredOilGrams: EstimateRange?
    let clarification: ClarificationQuestion?
    let attribution: String?
    let rawPhotoRetained: Bool

    var candidateNames: [String] {
        resolution?.candidates.map { $0.entry.name } ?? []
    }
}

enum MealCaptureOilAnswer: String, CaseIterable, Sendable {
    case noAdditionalOil
    case useEstimatedRange
}

enum MealCaptureApplicationError: Error, LocalizedError, Equatable {
    case foodDatabaseUnavailable
    case noPhotoEvidence
    case candidateSelectionRequired
    case invalidCandidate
    case portionUnavailable
    case mealVisionConsentRequired
    case clarificationAnswerRequired

    var errorDescription: String? {
        switch self {
        case .foodDatabaseUnavailable: "本地食物库尚未准备好。"
        case .noPhotoEvidence: "照片没有提供足够的条码、标签或菜品线索，请用语音补充。"
        case .candidateSelectionRequired: "请先确认最接近的食物候选。"
        case .invalidCandidate: "所选食物候选已经失效，请重新识别。"
        case .portionUnavailable: "请补充大致份量后再生成草稿。"
        case .mealVisionConsentRequired: "开放式照片需要单独同意向 Qwen 上传处理后的图片。"
        case .clarificationAnswerRequired: "请先回答这条识别澄清，再生成待确认草稿。"
        }
    }
}

@MainActor
final class MealCaptureApplicationService {
    private let foodDatabase: FoodDatabase?
    private let photoSanitizer: any MealPhotoSanitizing
    private let scanner: any MealImageScanning
    private let packagedFoodProvider: (any PackagedFoodProvider)?
    private let confirmedFoodHistory: (any ConfirmedFoodHistoryProviding)?
    private let visionProvider: (any MealVisionProviding)?
    private let governanceRepository: any ProviderGovernanceRepository
    private let providerConfiguration: ProviderConfigurationPreferences
    private let usageLedger: ProviderUsageLedger
    private let confirmationCoordinator: ConfirmationCoordinator
    private let qualityGate: MealVisionQualityGate
    private let portionEstimator: PortionEstimator
    private let mealEstimator: MealEstimator
    private let nutritionParser: NutritionLabelParser

    init(
        foodDatabase: FoodDatabase?,
        photoSanitizer: any MealPhotoSanitizing = ImageIOMealPhotoSanitizer(),
        scanner: any MealImageScanning = LocalMealImageScanner(),
        packagedFoodProvider: (any PackagedFoodProvider)? = nil,
        confirmedFoodHistory: (any ConfirmedFoodHistoryProviding)? = nil,
        visionProvider: (any MealVisionProviding)? = nil,
        governanceRepository: any ProviderGovernanceRepository,
        providerConfiguration: ProviderConfigurationPreferences,
        usageLedger: ProviderUsageLedger,
        confirmationCoordinator: ConfirmationCoordinator,
        qualityGate: MealVisionQualityGate = .unavailable,
        portionEstimator: PortionEstimator = .init(),
        mealEstimator: MealEstimator = .init(),
        nutritionParser: NutritionLabelParser = .init()
    ) {
        self.foodDatabase = foodDatabase
        self.photoSanitizer = photoSanitizer
        self.scanner = scanner
        self.packagedFoodProvider = packagedFoodProvider
        self.confirmedFoodHistory = confirmedFoodHistory
        self.visionProvider = visionProvider
        self.governanceRepository = governanceRepository
        self.providerConfiguration = providerConfiguration
        self.usageLedger = usageLedger
        self.confirmationCoordinator = confirmationCoordinator
        self.qualityGate = qualityGate
        self.portionEstimator = portionEstimator
        self.mealEstimator = mealEstimator
        self.nutritionParser = nutritionParser
    }

    func analyzePhoto(_ originalData: Data, locale: Locale = Locale(identifier: "zh-CN")) async throws -> MealCaptureReview {
        guard let foodDatabase else { throw MealCaptureApplicationError.foodDatabaseUnavailable }
        let sanitized = try await photoSanitizer.sanitize(originalData: originalData)
        let localEvidence = try await scanner.scan(imageJPEG: sanitized)

        let barcode = localEvidence.first(where: { $0.kind == .barcode })
        if let barcode, let packagedFoodProvider {
            do {
                if let packaged = try await packagedFoodProvider.lookup(barcode: barcode.value) {
                    return try packagedReview(
                        packaged,
                        nutrition: parsedNutrition(from: localEvidence),
                        evidence: localEvidence
                    )
                }
            } catch {
                // A valid GTIN remains a local/manual path on provider failure.
                // It must never turn into permission to upload the photo to Qwen.
            }
        }

        let labelLines = localEvidence
            .filter { $0.kind == .nutritionLabel }
            .flatMap { $0.value.split(separator: "\n").map(String.init) }
        if let nutrition = nutritionParser.parse(lines: labelLines) {
            return try nutritionLabelReview(nutrition, evidence: localEvidence)
        }

        if barcode != nil { return manualReview(evidence: localEvidence) }

        guard qualityGate.allowsOpenPhoto,
              providerConfiguration.qwenMealVisionEnabled,
              let visionProvider else {
            return manualReview(evidence: localEvidence)
        }
        guard try await governanceRepository.isConsentGranted(
            provider: .qwen,
            dataClass: .mealImage
        ) else {
            throw MealCaptureApplicationError.mealVisionConsentRequired
        }

        let observation = try await visionProvider.analyze(imageJPEG: sanitized, locale: locale)
        if let usage = observation.usage {
            try? await usageLedger.record(
                ProviderUsage(
                    provider: .qwen,
                    model: observation.modelVersion,
                    capability: .vision,
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    audioSeconds: 0,
                    attempt: usage.attempt
                ),
                requestID: UUID()
            )
        }
        let visionEvidence = observation.labels.map {
            MealEvidence(
                kind: .foodCandidate,
                value: $0,
                confidence: observation.isOccluded ? 0.45 : 0.75,
                sourceVersion: observation.modelVersion
            )
        }
        guard observation.labels.count == 1,
              let label = observation.labels.first else {
            if observation.labels.isEmpty {
                throw MealCaptureApplicationError.noPhotoEvidence
            }
            return manualReview(evidence: localEvidence + visionEvidence)
        }
        let catalog = try foodDatabase.catalogEntries()
        let preparation = observation.preparationHints.first ?? .unknown
        let history = (try? await confirmedFoodHistory?.confirmedFoodIDs(matching: label)) ?? []
        let resolution = FoodResolver(catalog: catalog).resolve(
            FoodResolutionQuery(
                label: label,
                preparation: preparation,
                sourceQuality: observation.isOccluded ? 0.45 : 0.75,
                confirmedHistoryFoodIDs: history
            )
        )
        let portion = try portionEstimator.estimate(
            evidence: [
                .photo(
                    likelyGrams: Self.grams(from: observation.portionHint) ?? 180,
                    hasScale: false,
                    isMixedDish: observation.labels.count > 1,
                    isOccluded: observation.isOccluded,
                    unknownContainer: observation.containerHint == nil
                )
            ],
            food: resolution.autoPreselect
        )
        let oilRange = try CookingOilPriorTable().range(for: observation.cookingMethod)
        let clarification = try makeClarification(
            label: label,
            resolution: resolution,
            portion: portion,
            cookingMethod: observation.cookingMethod,
            oilRange: oilRange
        )
        return MealCaptureReview(
            id: UUID(),
            route: .qwenVision,
            evidence: localEvidence + visionEvidence,
            label: label,
            resolution: resolution,
            portion: portion,
            cookingMethod: observation.cookingMethod,
            inferredOilGrams: oilRange,
            clarification: clarification,
            attribution: nil,
            rawPhotoRetained: false
        )
    }

    /// Sanitizes a photo and keeps its local scan evidence separate from the
    /// image bytes. The returned request is passed to AgentSession, which only
    /// stages a pending action after the model invokes the existing meal tool.
    func prepareForAgent(
        originalData: Data,
        userText: String = "请根据这张餐食照片协助我记录，生成待确认草稿；不确定的部分先提出一个问题。"
    ) async throws -> MultimodalModelRequest {
        let sanitized = try await photoSanitizer.sanitize(originalData: originalData)
        let localEvidence = try await scanner.scan(imageJPEG: sanitized)
        return try MultimodalModelRequest(
            userText: userText,
            imageJPEG: sanitized,
            mealEvidence: localEvidence
        )
    }

    func stageMeal(
        review: MealCaptureReview,
        selectedFoodID: String?,
        correctedPortion: PortionEstimate? = nil,
        oilAnswer: MealCaptureOilAnswer? = nil,
        mealType: String = "lunch",
        occurredAt: Date = Date(),
        clientRequestID: UUID? = nil
    ) async throws -> PendingAction {
        guard let originalResolution = review.resolution else {
            throw MealCaptureApplicationError.candidateSelectionRequired
        }
        let selected: FoodCandidate
        if let selectedFoodID {
            guard let match = originalResolution.candidates.first(where: { $0.id == selectedFoodID }) else {
                throw MealCaptureApplicationError.invalidCandidate
            }
            selected = match
        } else if let automatic = originalResolution.autoPreselect {
            selected = automatic
        } else {
            throw MealCaptureApplicationError.candidateSelectionRequired
        }
        if review.clarification?.kind == .portion, correctedPortion == nil {
            throw MealCaptureApplicationError.clarificationAnswerRequired
        }
        if review.clarification?.kind == .hiddenIngredient, oilAnswer == nil {
            throw MealCaptureApplicationError.clarificationAnswerRequired
        }
        guard let portion = correctedPortion ?? review.portion else {
            throw MealCaptureApplicationError.portionUnavailable
        }
        let confirmedResolution = FoodResolution(
            candidates: originalResolution.candidates,
            autoPreselect: selected
        )
        var captureEvidence = review.evidence.map { evidence in
            EvidenceSnapshot(
                grade: evidence.kind == .barcode || evidence.kind == .nutritionLabel
                    ? .label
                    : .estimated,
                sourceID: "capture:\(evidence.kind.rawValue)",
                sourceVersion: evidence.sourceVersion,
                summary: String(evidence.value.prefix(160)),
                confidence: evidence.confidence
            )
        }
        captureEvidence.append(
            EvidenceSnapshot(
                grade: selectedFoodID == nil ? .estimated : .userReported,
                sourceID: selectedFoodID == nil
                    ? "auto-preselected-candidate"
                    : "user-selected-candidate",
                sourceVersion: MealEstimator.algorithmVersion,
                summary: selected.entry.name,
                confidence: selectedFoodID == nil ? nil : 1
            )
        )
        if let attribution = review.attribution {
            captureEvidence.append(
                EvidenceSnapshot(
                    grade: .label,
                    sourceID: "packaged-food-attribution",
                    sourceVersion: selected.entry.sourceVersion,
                    summary: String(attribution.prefix(200)),
                    confidence: nil
                )
            )
        }
        if correctedPortion != nil {
            captureEvidence.append(
                EvidenceSnapshot(
                    grade: .userReported,
                    sourceID: "user-corrected-portion",
                    sourceVersion: MealEstimator.algorithmVersion,
                    summary: "\(portion.likelyGrams)g",
                    confidence: 1
                )
            )
        }
        if let oilAnswer {
            captureEvidence.append(
                EvidenceSnapshot(
                    grade: .userReported,
                    sourceID: "user-clarified-oil",
                    sourceVersion: MealEstimator.algorithmVersion,
                    summary: oilAnswer == .noAdditionalOil
                        ? "用户报告：没有额外加入烹饪用油"
                        : "用户同意采用烹饪方式的用油估算范围",
                    confidence: 1
                )
            )
        }
        let oilEstimate: EstimateRange? = oilAnswer == .noAdditionalOil
            ? nil
            : review.inferredOilGrams
        let dish = try mealEstimator.estimateDish(
            MealDishEstimationInput(
                name: review.label,
                cookingMethod: review.cookingMethod,
                ingredients: [
                    MealIngredientEstimationInput(
                        label: review.label,
                        resolution: confirmedResolution,
                        portion: portion,
                        massBasis: selected.entry.preparation == .cooked ? .cooked : .edibleRaw,
                        additionalEvidence: captureEvidence
                    )
                ],
                inferredOilGrams: oilEstimate
            )
        )
        let payload = ActionPayload.meal(
            MealDraft(
                occurredAt: occurredAt,
                mealType: mealType,
                dishes: [dish],
                note: nil
            )
        )
        return try await confirmationCoordinator.stage(
            payload: payload,
            clientRequestID: clientRequestID ?? review.id
        )
    }

    private func packagedReview(
        _ packaged: PackagedFoodMatch,
        nutrition: PackagedNutritionObservation?,
        evidence: [MealEvidence]
    ) throws -> MealCaptureReview {
        let packagedEvidence = evidence + [
            MealEvidence(
                kind: .foodCandidate,
                value: packaged.displayName,
                confidence: 1,
                sourceVersion: packaged.providerID
            )
        ]
        let labelScale: Double
        let labelServing: Double?
        if let nutrition {
            switch nutrition.basis {
            case .per100Grams:
                labelScale = 1
                labelServing = nil
            case .perServing(let grams):
                labelScale = 100 / max(grams, 1)
                labelServing = grams
            }
        } else {
            labelScale = 1
            labelServing = nil
        }
        guard let energy = packaged.caloriesPer100Grams ?? nutrition.map({ $0.energyKcal * labelScale }) else {
            return manualReview(evidence: packagedEvidence)
        }
        let entry = FoodCatalogEntry(
            id: "barcode:\(packaged.barcode)",
            name: packaged.displayName,
            aliases: [],
            preparation: .unknown,
            category: "packaged",
            nutrients: FoodNutrientProfile(
                energyKcalPer100Grams: energy,
                proteinGramsPer100Grams: nutrition?.proteinGrams.map { $0 * labelScale },
                fatGramsPer100Grams: nutrition?.fatGrams.map { $0 * labelScale },
                carbohydrateGramsPer100Grams: nutrition?.carbohydrateGrams.map { $0 * labelScale }
            ),
            sourceVersion: packaged.providerID
        )
        let resolution = exactResolution(
            entry,
            sourceID: "barcode:\(packaged.barcode)",
            isBarcode: true
        )
        let serving = packaged.servingGrams ?? labelServing
        let portion = try portionEstimator.estimate(
            evidence: serving.map {
                [.packageServing(gramsPerServing: $0, count: 1)]
            } ?? [.photo(likelyGrams: 100, hasScale: false, isMixedDish: false, isOccluded: false, unknownContainer: true)],
            food: resolution.autoPreselect
        )
        return MealCaptureReview(
            id: UUID(), route: .packagedBarcode, evidence: packagedEvidence,
            label: packaged.displayName, resolution: resolution, portion: portion,
            cookingMethod: nil, inferredOilGrams: nil, clarification: nil,
            attribution: packaged.attribution,
            rawPhotoRetained: false
        )
    }

    private func manualReview(evidence: [MealEvidence]) -> MealCaptureReview {
        MealCaptureReview(
            id: UUID(),
            route: .manualDescription,
            evidence: evidence,
            label: "请用语音描述这张餐食照片",
            resolution: nil,
            portion: nil,
            cookingMethod: nil,
            inferredOilGrams: nil,
            clarification: nil,
            attribution: nil,
            rawPhotoRetained: false
        )
    }

    private func nutritionLabelReview(
        _ nutrition: PackagedNutritionObservation,
        evidence: [MealEvidence]
    ) throws -> MealCaptureReview {
        let name = nutrition.productName ?? "包装食品"
        let servingGrams: Double
        let scale: Double
        switch nutrition.basis {
        case .per100Grams:
            servingGrams = 100
            scale = 1
        case .perServing(let grams):
            servingGrams = grams
            scale = 100 / max(grams, 1)
        }
        let entry = FoodCatalogEntry(
            id: "label:\(FoodResolver.normalize(name))",
            name: name,
            preparation: .unknown,
            category: "packaged",
            nutrients: FoodNutrientProfile(
                energyKcalPer100Grams: nutrition.energyKcal * scale,
                proteinGramsPer100Grams: nutrition.proteinGrams.map { $0 * scale },
                fatGramsPer100Grams: nutrition.fatGrams.map { $0 * scale },
                carbohydrateGramsPer100Grams: nutrition.carbohydrateGrams.map { $0 * scale }
            ),
            sourceVersion: "local-vision-label-v1"
        )
        let resolution = exactResolution(entry, sourceID: "nutrition-label")
        let portion = try portionEstimator.estimate(
            evidence: [.packageServing(gramsPerServing: servingGrams, count: 1)],
            food: resolution.autoPreselect
        )
        return MealCaptureReview(
            id: UUID(), route: .nutritionLabel, evidence: evidence,
            label: name, resolution: resolution, portion: portion,
            cookingMethod: nil, inferredOilGrams: nil, clarification: nil,
            attribution: nil,
            rawPhotoRetained: false
        )
    }

    private func parsedNutrition(from evidence: [MealEvidence]) -> PackagedNutritionObservation? {
        let lines = evidence
            .filter { $0.kind == .nutritionLabel }
            .flatMap { $0.value.split(separator: "\n").map(String.init) }
        return nutritionParser.parse(lines: lines)
    }

    private func exactResolution(
        _ entry: FoodCatalogEntry,
        sourceID: String,
        isBarcode: Bool = false
    ) -> FoodResolution {
        let localResolution = FoodResolver(catalog: [entry]).resolve(
            FoodResolutionQuery(
                label: entry.name,
                preparation: entry.preparation,
                categoryHint: entry.category,
                sourceQuality: 1,
                barcodeMatchedFoodID: isBarcode ? entry.id : nil
            )
        )
        let candidates = localResolution.candidates.map { candidate in
            FoodCandidate(
                entry: candidate.entry,
                score: candidate.score,
                breakdown: candidate.breakdown,
                evidence: candidate.evidence + [
                    EvidenceSnapshot(
                        grade: .label,
                        sourceID: sourceID,
                        sourceVersion: entry.sourceVersion,
                        summary: entry.name,
                        confidence: 1
                    )
                ]
            )
        }
        let selected = candidates.first
        return FoodResolution(candidates: candidates, autoPreselect: selected)
    }

    private func makeClarification(
        label: String,
        resolution: FoodResolution,
        portion: PortionEstimate,
        cookingMethod: String?,
        oilRange: EstimateRange?
    ) throws -> ClarificationQuestion? {
        guard !resolution.candidates.isEmpty else { return nil }
        let provisional = try mealEstimator.estimateDish(
            MealDishEstimationInput(
                name: label,
                cookingMethod: cookingMethod,
                ingredients: [
                    MealIngredientEstimationInput(
                        label: label,
                        resolution: resolution,
                        portion: portion,
                        massBasis: resolution.autoPreselect?.entry.preparation == .cooked
                            ? .cooked
                            : .edibleRaw
                    )
                ],
                inferredOilGrams: oilRange
            )
        )
        var candidates: [ClarificationCandidate] = []
        if resolution.autoPreselect == nil {
            candidates.append(
                ClarificationCandidate(
                    kind: .foodIdentity,
                    prompt: "更接近 \(resolution.candidates.map { $0.entry.name }.joined(separator: "，")) 中的哪一种？",
                    expectedEnergyRangeReduction: 0.45,
                    userEffort: 1
                )
            )
        }
        candidates.append(
            ClarificationCandidate(
                kind: .portion,
                    prompt: "这一份大约多少克？",
                expectedEnergyRangeReduction: 0.35,
                userEffort: 1
            )
        )
        if oilRange != nil {
            candidates.append(
                ClarificationCandidate(
                    kind: .hiddenIngredient,
                    prompt: "这道菜是否额外加入了烹饪用油？",
                    expectedEnergyRangeReduction: 0.25,
                    userEffort: 1
                )
            )
        }
        return ClarificationSelector().selectOne(
            from: ClarificationContext(
                energyKcal: provisional.nutrients.energyKcal,
                candidates: candidates
            )
        )
    }

    private static func grams(from hint: String?) -> Double? {
        guard let hint,
              let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:g|克)"#),
              let match = regex.firstMatch(
                  in: hint,
                  range: NSRange(hint.startIndex..<hint.endIndex, in: hint)
              ),
              let capture = Range(match.range(at: 1), in: hint) else { return nil }
        return Double(hint[capture])
    }
}
