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

enum MealCapturePreparation: Sendable {
    case agentRequest(MultimodalModelRequest)
    case localReview(MealCaptureReview)
    case textOnlyFallback(String)
}

enum LocalMealPortionAnswer: Equatable, Sendable {
    case grams(Double)
    case servings(Double)
}

struct LocalMealPortionAnswerParser: Sendable {
    func parse(
        _ text: String,
        matching ingredient: String,
        allowBareAmount: Bool
    ) -> LocalMealPortionAnswer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return nil }

        if allowBareAmount,
           let grams = amount(
            in: trimmed,
            pattern: #"^\s*([0-9]+(?:\.[0-9]+)?)\s*(?:g|grams?|克|公克)\s*$"#
           ) {
            return .grams(grams)
        }
        if let grams = ExplicitUserGramsParser().exactGrams(
            in: trimmed,
            matching: [ingredient]
        ) {
            return .grams(grams)
        }
        if !allowBareAmount, let standaloneAnswer = standaloneAnswer(trimmed) {
            return standaloneAnswer
        }

        let needsConsumptionContext = !allowBareAmount
        guard !needsConsumptionContext || Self.hasConsumptionContext(trimmed) else {
            return nil
        }
        if needsConsumptionContext, let grams = Self.singleUnhedgedGramAmount(in: trimmed) {
            return .grams(grams)
        }
        let normalized = trimmed.lowercased()
        if ["半份", "半包", "半袋", "half a serving", "half serving"].contains(where: normalized.contains) {
            return .servings(0.5)
        }
        let chineseCounts: [(String, Double)] = [
            ("两份", 2), ("二份", 2), ("三份", 3), ("一份", 1),
            ("两包", 2), ("二包", 2), ("三包", 3), ("一包", 1),
            ("两袋", 2), ("二袋", 2), ("一袋", 1),
        ]
        if let match = chineseCounts.first(where: { normalized.contains($0.0) }) {
            return .servings(match.1)
        }
        if let count = amount(
            in: trimmed,
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:份|包|袋|盒|瓶|servings?|packages?)"#
        ), (0.1...20).contains(count) {
            return .servings(count)
        }
        return nil
    }

    private static func hasConsumptionContext(_ text: String) -> Bool {
        ["吃", "喝", "食用", "摄入", "ate", "consumed", "had"].contains {
            text.localizedCaseInsensitiveContains($0)
        }
    }

    private func standaloneAnswer(_ text: String) -> LocalMealPortionAnswer? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["半份", "半包", "半袋"].contains(normalized) { return .servings(0.5) }
        let chineseCounts: [(String, Double)] = [
            ("一份", 1), ("二份", 2), ("两份", 2), ("三份", 3),
            ("一包", 1), ("二包", 2), ("两包", 2), ("三包", 3),
            ("一袋", 1), ("二袋", 2), ("两袋", 2), ("三袋", 3),
        ]
        if let match = chineseCounts.first(where: { $0.0 == normalized }) {
            return .servings(match.1)
        }
        if let count = amount(
            in: normalized,
            pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*(?:份|包|袋|盒|瓶|servings?|packages?)$"#
        ), (0.1...20).contains(count) {
            return .servings(count)
        }
        if let grams = amount(
            in: normalized,
            pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*(?:g|grams?|克|公克)$"#
        ), (0.1...5_000).contains(grams) {
            return .grams(grams)
        }
        return nil
    }

    private static func singleUnhedgedGramAmount(in text: String) -> Double? {
        let normalized = text.lowercased()
        let hedges = ["约", "大约", "左右", "差不多", "大概", "about", "around", "approximately"]
        guard !hedges.contains(where: normalized.contains),
              let rangeRegex = try? NSRegularExpression(
                pattern: #"[0-9]+(?:\.[0-9]+)?\s*(?:-|–|~|至|到|to)\s*[0-9]+(?:\.[0-9]+)?\s*(?:g|grams?|克|公克)"#,
                options: [.caseInsensitive]
              ) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard rangeRegex.firstMatch(in: text, range: fullRange) == nil,
              let gramRegex = try? NSRegularExpression(
                pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:g|grams?|克|公克)"#,
                options: [.caseInsensitive]
              ) else {
            return nil
        }
        let matches = gramRegex.matches(in: text, range: fullRange)
        guard matches.count == 1,
              let valueRange = Range(matches[0].range(at: 1), in: text),
              let value = Double(text[valueRange]),
              value.isFinite,
              (0.1...5_000).contains(value) else {
            return nil
        }
        return value
    }

    private func amount(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        guard let value = Double(String(text[range])), value.isFinite else { return nil }
        return value
    }
}

enum MealCaptureOilAnswer: String, CaseIterable, Sendable {
    case noAdditionalOil
    case useEstimatedRange
}

enum MealCaptureApplicationError: Equatable, SharedErrorDescribing {
    case foodDatabaseUnavailable
    case noPhotoEvidence
    case candidateSelectionRequired
    case invalidCandidate
    case portionUnavailable
    case mealVisionConsentRequired
    case clarificationAnswerRequired

    private var safeDetails: (code: SharedErrorCode, reason: SharedErrorReason, message: String) {
        switch self {
        case .foodDatabaseUnavailable:
            (.providerUnavailable, .unsupportedCapability, "本地食物库尚未准备好。")
        case .noPhotoEvidence:
            (.toolArgumentsInvalid, .invalidToolArguments, "照片没有提供足够的条码、标签或菜品线索，请用语音补充。")
        case .candidateSelectionRequired:
            (.toolArgumentsInvalid, .invalidToolArguments, "请先确认最接近的食物候选。")
        case .invalidCandidate:
            (.actionConflict, .actionNotFound, "所选食物候选已经失效，请重新识别。")
        case .portionUnavailable:
            (.toolArgumentsInvalid, .invalidToolArguments, "请补充大致份量后再生成草稿。")
        case .mealVisionConsentRequired:
            (.actionConflict, .consentRequired, "开放式照片需要单独同意向 Qwen 上传处理后的图片。")
        case .clarificationAnswerRequired:
            (.toolArgumentsInvalid, .invalidToolArguments, "请先回答这条识别澄清，再生成待确认草稿。")
        }
    }

    var sharedErrorDescriptor: SharedErrorDescriptor {
        SharedErrorDescriptor(
            code: safeDetails.code,
            userMessage: safeDetails.message,
            subsystem: .agent,
            reason: safeDetails.reason
        )
    }

    var errorDescription: String? { sharedErrorDescriptor.userMessage }
}

@MainActor
final class MealCaptureApplicationService {
    static let promptVersion = MealPromptVersion.current

    private let foodDatabase: FoodDatabase?
    private let photoSanitizer: any MealPhotoSanitizing
    private let scanner: any MealImageScanning
    private let packagedFoodProvider: (any PackagedFoodProvider)?
    private let allowsRemotePackagedFoodLookup: Bool
    private let confirmedFoodHistory: (any ConfirmedFoodHistoryProviding)?
    private let visionProvider: (any MealVisionProviding)?
    private let allowsQwenMealVision: Bool
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
        allowsRemotePackagedFoodLookup: Bool = true,
        confirmedFoodHistory: (any ConfirmedFoodHistoryProviding)? = nil,
        visionProvider: (any MealVisionProviding)? = nil,
        allowsQwenMealVision: Bool = false,
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
        self.allowsRemotePackagedFoodLookup = allowsRemotePackagedFoodLookup
        self.confirmedFoodHistory = confirmedFoodHistory
        self.visionProvider = visionProvider
        self.allowsQwenMealVision = allowsQwenMealVision
        self.governanceRepository = governanceRepository
        self.providerConfiguration = providerConfiguration
        self.usageLedger = usageLedger
        self.confirmationCoordinator = confirmationCoordinator
        self.qualityGate = qualityGate
        self.portionEstimator = portionEstimator
        self.mealEstimator = mealEstimator
        self.nutritionParser = nutritionParser
    }

    /// Optional Qwen review path. The default photo flow uses the selected
    /// multimodal Agent provider; this path is enabled only for an explicitly
    /// selected Qwen mode with its own feature gate and consent.
    func analyzePhoto(_ originalData: Data, locale: Locale = Locale(identifier: "zh-CN")) async throws -> MealCaptureReview {
        guard let foodDatabase else { throw MealCaptureApplicationError.foodDatabaseUnavailable }
        let sanitized = try await photoSanitizer.sanitize(originalData: originalData)
        let localEvidence = try await scanner.scan(imageJPEG: sanitized)

        let barcode = localEvidence.first(where: { $0.kind == .barcode })
        if allowsRemotePackagedFoodLookup,
           let barcode,
           let packagedFoodProvider {
            do {
                if let packaged = try await packagedFoodProvider.lookup(barcode: barcode.value) {
                    return try await packagedReview(
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
            return try await nutritionLabelReview(nutrition, evidence: localEvidence)
        }

        if barcode != nil { return manualReview(evidence: localEvidence) }

        guard qualityGate.allowsOpenPhoto,
              allowsQwenMealVision,
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
        let resolution = FoodResolverV2(catalog: catalog).resolve(
            FoodResolutionV2Query(
                label: label,
                preparation: preparation,
                massBasis: Self.massBasis(for: preparation),
                sourceQuality: observation.isOccluded ? 0.45 : 0.75,
                confirmedHistoryFoodIDs: history,
                evidence: localEvidence + visionEvidence
            )
        ).mealEstimatorResolution
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
        userText: String = "请根据这张餐食照片协助我记录，生成待确认草稿；不确定的部分先提出一个问题。",
        onImageStateChange: (@MainActor (MealImageCaptureState) -> Void)? = nil
    ) async throws -> MealCapturePreparation {
        onImageStateChange?(.sanitizing)
        let sanitized = try await photoSanitizer.sanitize(originalData: originalData)
        try Task.checkCancellation()
        onImageStateChange?(.localScanning)
        let localEvidence = try await scanner.scan(imageJPEG: sanitized)
        try Task.checkCancellation()

        if let barcode = localEvidence.first(where: { $0.kind == .barcode }) {
            if allowsRemotePackagedFoodLookup,
               let packagedFoodProvider {
                do {
                    if let packaged = try await packagedFoodProvider.lookup(barcode: barcode.value) {
                        let review = try await packagedReview(
                            packaged,
                            nutrition: parsedNutrition(from: localEvidence),
                            evidence: localEvidence
                        )
                        if review.route == .packagedBarcode {
                            onImageStateChange?(.localResolved)
                            return .localReview(review)
                        }
                        onImageStateChange?(.localResolved)
                        return .textOnlyFallback(
                            "本机识别到包装候选「\(packaged.displayName)」，但没有可用营养能量信息。请让用户补充包装营养信息或用文字描述；不要从条码推测营养，也不要上传这张图片。\n\n\(userText)"
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A scanned barcode remains a text-only/manual path on provider failure.
                }
            }
            onImageStateChange?(.localResolved)
            return .textOnlyFallback(
                "本机识别到包装条码，但没有可用的本地商品匹配。请让用户补充商品名称或营养信息；不要把条码数字当作食物名称，也不要上传这张图片。\n\n\(userText)"
            )
        }

        let labelLines = localEvidence
            .filter { $0.kind == .nutritionLabel }
            .flatMap { $0.value.split(separator: "\n").map(String.init) }
        if let nutrition = nutritionParser.parse(lines: labelLines) {
            onImageStateChange?(.localResolved)
            return .localReview(try await nutritionLabelReview(nutrition, evidence: localEvidence))
        }

        try Task.checkCancellation()
        onImageStateChange?(.deepseekRequired)
        return .agentRequest(try MultimodalModelRequest(
            userText: userText,
            imageJPEG: sanitized,
            mealEvidence: localEvidence
        ))
    }

    func stageMeal(
        review: MealCaptureReview,
        selectedFoodID: String?,
        correctedPortion: PortionEstimate? = nil,
        oilAnswer: MealCaptureOilAnswer? = nil,
        userNote: String? = nil,
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
            let summary: String
            switch evidence.kind {
            case .barcode:
                summary = "本地扫描到商品条码"
            case .nutritionLabel:
                summary = "本地识别到营养标签"
            default:
                summary = String(evidence.value.prefix(160))
            }
            return EvidenceSnapshot(
                grade: evidence.kind == .barcode || evidence.kind == .nutritionLabel
                    ? .label
                    : .estimated,
                sourceID: "capture:\(evidence.kind.rawValue)",
                sourceVersion: evidence.sourceVersion,
                summary: summary,
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
        let trimmedUserNote = userNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ActionPayload.meal(
            MealDraft(
                occurredAt: occurredAt,
                mealType: mealType,
                dishes: [dish],
                note: trimmedUserNote.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
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
    ) async throws -> MealCaptureReview {
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
        let history = (try? await confirmedFoodHistory?.confirmedFoodIDs(matching: packaged.displayName)) ?? []
        let resolution = resolveWithV2(
            entry,
            label: packaged.displayName,
            massBasis: .asPurchased,
            categoryHint: "packaged",
            sourceQuality: packagedEvidence.map(\.confidence).max() ?? 1,
            barcodeMatchedFoodID: entry.id,
            confirmedHistoryFoodIDs: history,
            evidence: packagedEvidence
        )
        let serving = packaged.servingGrams ?? labelServing
        let portion: PortionEstimate?
        if let serving {
            portion = try portionEstimator.estimate(
                evidence: [.packageServing(gramsPerServing: serving, count: 1)],
                food: resolution.autoPreselect
            )
        } else {
            portion = nil
        }
        return MealCaptureReview(
            id: UUID(), route: .packagedBarcode, evidence: packagedEvidence,
            label: packaged.displayName, resolution: resolution, portion: portion,
            cookingMethod: nil, inferredOilGrams: nil,
            clarification: Self.consumedPortionClarification(canConvertServingCount: serving != nil),
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
    ) async throws -> MealCaptureReview {
        let name = nutrition.productName ?? "包装食品"
        let servingGrams: Double?
        let scale: Double
        switch nutrition.basis {
        case .per100Grams:
            servingGrams = nil
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
        let labelEvidence = evidence.filter { $0.kind == .nutritionLabel }
        let history = (try? await confirmedFoodHistory?.confirmedFoodIDs(matching: name)) ?? []
        let resolution = resolveWithV2(
            entry,
            label: name,
            massBasis: .asPurchased,
            categoryHint: "packaged",
            sourceQuality: max(labelEvidence.map(\.confidence).max() ?? 0, 0.5),
            confirmedHistoryFoodIDs: history,
            evidence: labelEvidence + [
                MealEvidence(
                    kind: .nutritionLabel,
                    value: name,
                    confidence: labelEvidence.map(\.confidence).max() ?? 1,
                    sourceVersion: entry.sourceVersion
                )
            ]
        )
        let portion: PortionEstimate?
        if let servingGrams {
            portion = try portionEstimator.estimate(
                evidence: [.packageServing(gramsPerServing: servingGrams, count: 1)],
                food: resolution.autoPreselect
            )
        } else {
            portion = nil
        }
        return MealCaptureReview(
            id: UUID(), route: .nutritionLabel, evidence: evidence,
            label: name, resolution: resolution, portion: portion,
            cookingMethod: nil, inferredOilGrams: nil,
            clarification: Self.consumedPortionClarification(canConvertServingCount: servingGrams != nil),
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

    private func resolveWithV2(
        _ entry: FoodCatalogEntry,
        label: String,
        massBasis: FoodMassBasis?,
        categoryHint: String?,
        sourceQuality: Double,
        barcodeMatchedFoodID: String? = nil,
        confirmedHistoryFoodIDs: Set<String> = [],
        evidence: [MealEvidence]
    ) -> FoodResolution {
        FoodResolverV2(catalog: [entry]).resolve(
            FoodResolutionV2Query(
                label: label,
                preparation: entry.preparation,
                massBasis: massBasis,
                categoryHint: categoryHint,
                sourceQuality: sourceQuality,
                barcodeMatchedFoodID: barcodeMatchedFoodID,
                confirmedHistoryFoodIDs: confirmedHistoryFoodIDs,
                evidence: evidence
            )
        ).mealEstimatorResolution
    }

    private static func massBasis(for preparation: FoodPreparation) -> FoodMassBasis? {
        switch preparation {
        case .raw: .edibleRaw
        case .cooked: .cooked
        case .unknown: nil
        }
    }

    private static func consumedPortionClarification(
        canConvertServingCount: Bool
    ) -> ClarificationQuestion {
        ClarificationQuestion(
            kind: .portion,
            prompt: canConvertServingCount
                ? "标签或包装规格不能确定本次实际份量；请填写克数，或按已知每份重量填写份数。"
                : "本机没有可换算的每份重量；请填写这次实际吃下的大约克数。"
        )
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
