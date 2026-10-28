import CoreGraphics
import DensosoDomain
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Densoso

@MainActor
final class MealCaptureApplicationServiceTests: XCTestCase {
    func testMealCaptureErrorsExposeSharedSafeDescriptors() {
        let photoError = MealCaptureApplicationError.noPhotoEvidence
        let consentError = MealCaptureApplicationError.mealVisionConsentRequired

        XCTAssertEqual(photoError.sharedErrorDescriptor.code, .toolArgumentsInvalid)
        XCTAssertEqual(photoError.localizedDescription, photoError.sharedErrorDescriptor.userMessage)
        XCTAssertEqual(consentError.sharedErrorDescriptor.code, .actionConflict)
        XCTAssertEqual(consentError.sharedErrorDescriptor.reason, .consentRequired)
        XCTAssertEqual(consentError.localizedDescription, consentError.sharedErrorDescriptor.userMessage)
    }

    func testManualMealRequiresSourceBackedMassBasisWhileLabelRouteUsesPurchasedBasis() async throws {
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: FakeMealVisionProvider(),
            imageConsent: false,
            imageEnabled: false
        )
        let unverifiedFoodSeed = #"""
        [
          {"id":71,"name":"苹果","alias":"苹果","preparation":"raw","category":"水果类及制品","edible":50,"energyKcal":100,"proteinG":1,"fatG":1,"carbohydrateG":20,"fiberG":2}
        ]
        """#
        let unverifiedDatabase = try FoodDatabase(seedJSON: Data(unverifiedFoodSeed.utf8))
        let entries = try unverifiedDatabase.catalogEntries()
        let resolution = FoodResolverV2(catalog: entries).resolve(
            FoodResolutionV2Query(label: "苹果", preparation: .raw, sourceQuality: 1)
        ).mealEstimatorResolution
        let selected = try XCTUnwrap(resolution.autoPreselect)
        let portion = try PortionEstimator().estimate(
            evidence: [.userCorrection(low: 100, likely: 100, high: 100)],
            food: selected
        )
        func review(route: MealCaptureReview.Route) -> MealCaptureReview {
            MealCaptureReview(
                id: UUID(), route: route, evidence: [], label: "苹果",
                resolution: resolution, portion: portion, cookingMethod: nil,
                inferredOilGrams: nil, clarification: nil, attribution: nil,
                rawPhotoRetained: false
            )
        }

        do {
            _ = try await harness.service.stageMeal(
                review: review(route: .manualDescription),
                selectedFoodID: nil
            )
            XCTFail("Manual meal weights need an explicit or source-backed mass basis")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .massBasisUnavailable)
        }
        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 0)

        let labelAction = try await harness.service.stageMeal(
            review: review(route: .nutritionLabel),
            selectedFoodID: nil
        )
        guard case .meal(let draft) = labelAction.payload else {
            return XCTFail("Expected a packaged-label meal draft")
        }
        XCTAssertEqual(draft.totalNutrients?.energyKcal.likely ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
    }

    func testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount() {
        let parser = LocalMealPortionAnswerParser()

        XCTAssertEqual(parser.parse("2份", matching: "测试燕麦棒", allowBareAmount: true), .servings(2))
        XCTAssertEqual(parser.parse("2包", matching: "测试燕麦棒", allowBareAmount: false), .servings(2))
        XCTAssertEqual(parser.parse("半包", matching: "测试燕麦棒", allowBareAmount: true), .servings(0.5))
        XCTAssertEqual(parser.parse("我吃了2包", matching: "测试燕麦棒", allowBareAmount: false), .servings(2))
        XCTAssertEqual(parser.parse("180克", matching: "测试燕麦棒", allowBareAmount: true), .grams(180))
        XCTAssertEqual(parser.parse("180g", matching: "测试燕麦棒", allowBareAmount: false), .grams(180))
        XCTAssertNil(parser.parse("2", matching: "测试燕麦棒", allowBareAmount: true))
        XCTAssertEqual(parser.parse("我吃了180克", matching: "测试燕麦棒", allowBareAmount: false), .grams(180))
        XCTAssertNil(parser.parse("我吃了约180克", matching: "测试燕麦棒", allowBareAmount: false))
        XCTAssertNil(parser.parse("我吃了180克或250克", matching: "测试燕麦棒", allowBareAmount: false))
        XCTAssertNil(parser.parse(
            String(repeating: "我吃了180克 ", count: 100),
            matching: "测试燕麦棒",
            allowBareAmount: false
        ))
        XCTAssertNil(parser.parse("包装规格每份 250g", matching: "测试燕麦棒", allowBareAmount: false))
        XCTAssertNil(parser.parse("包装标注 2份", matching: "测试燕麦棒", allowBareAmount: false))
        XCTAssertNil(parser.parse("我今天运动2小时", matching: "测试燕麦棒", allowBareAmount: false))
    }

    func testBarcodeMatchSkipsQwenAndStillCreatesOnlyPendingAction() async throws {
        let scanner = FakeMealImageScanner(evidence: [
            MealEvidence(kind: .barcode, value: "6901234567892", confidence: 1)
        ])
        let packaged = FakePackagedFoodProvider(
            match: PackagedFoodMatch(
                barcode: "6901234567892",
                displayName: "测试燕麦棒",
                servingGrams: 40,
                caloriesPer100Grams: 420,
                providerID: "fixture"
            )
        )
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: scanner,
            packagedFoodProvider: packaged,
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())
        let barcodeCandidate = try XCTUnwrap(review.resolution?.autoPreselect)
        let correction = try PortionEstimator().estimate(
            evidence: [.userCorrection(low: 40, likely: 40, high: 40)],
            food: barcodeCandidate
        )
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: nil,
            correctedPortion: correction
        )

        XCTAssertEqual(review.route, .packagedBarcode)
        XCTAssertFalse(review.rawPhotoRetained)
        XCTAssertEqual(barcodeCandidate.evidence.first?.sourceID, "barcode")
        XCTAssertEqual(barcodeCandidate.evidence.first?.grade, .label)
        XCTAssertEqual(barcodeCandidate.breakdown.sourceQuality, 1)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
        XCTAssertEqual(action.state, .pending)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected meal payload")
        }
        XCTAssertFalse(draft.dishes.flatMap(\.evidence).contains {
            $0.summary.contains("6901234567892")
        })
        XCTAssertFalse(draft.dishes.flatMap(\.evidence).contains {
            $0.sourceID == "user-selected-candidate"
        })
        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
    }

    func testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction() async throws {
        let barcode = "6901234567892"
        let scanner = FakeMealImageScanner(evidence: [
            MealEvidence(kind: .barcode, value: barcode, confidence: 1)
        ])
        let packaged = FakePackagedFoodProvider(
            match: PackagedFoodMatch(
                barcode: barcode,
                displayName: "测试燕麦棒",
                servingGrams: 40,
                caloriesPer100Grams: 420,
                providerID: "fixture"
            )
        )
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: scanner,
            packagedFoodProvider: packaged,
            visionProvider: vision,
            imageConsent: false,
            imageEnabled: true
        )

        let result = try await harness.service.prepareForAgent(originalData: try fixtureJPEG())
        guard case .localReview(let review) = result else {
            return XCTFail("A locally matched barcode must not create an image request")
        }
        XCTAssertEqual(review.route, .packagedBarcode)
        XCTAssertFalse(review.rawPhotoRetained)
        XCTAssertTrue(review.clarification?.prompt.contains("份数") == true)
        let correction = try PortionEstimator().estimate(
            evidence: [.userCorrection(low: 40, likely: 40, high: 40)],
            food: review.resolution?.autoPreselect
        )
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: nil,
            correctedPortion: correction,
            userNote: "不加糖"
        )
        XCTAssertEqual(action.state, .pending)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected a local meal pending action")
        }
        XCTAssertEqual(draft.note, "不加糖")
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)

        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
    }

    func testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion() async throws {
        let scanner = FakeMealImageScanner(evidence: [
            MealEvidence(
                kind: .nutritionLabel,
                value: "测试饮料\n每100g\n能量 80 kcal\n蛋白质 3g",
                confidence: 0.95,
                sourceVersion: "local-ocr"
            )
        ])
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: scanner,
            visionProvider: vision,
            imageConsent: false,
            imageEnabled: true
        )

        let result = try await harness.service.prepareForAgent(originalData: try fixtureJPEG())
        guard case .localReview(let review) = result else {
            return XCTFail("A complete local nutrition label must not create an image request")
        }
        XCTAssertEqual(review.route, .nutritionLabel)
        XCTAssertNil(review.portion, "Per-100g density is not the amount eaten")
        XCTAssertEqual(review.clarification?.kind, .portion)
        XCTAssertTrue(review.clarification?.prompt.contains("没有可换算的每份重量") == true)
        do {
            _ = try await harness.service.stageMeal(review: review, selectedFoodID: nil)
            XCTFail("The local route must ask once when consumed portion is missing")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .clarificationAnswerRequired)
        }

        let correction = try PortionEstimator().estimate(
            evidence: [.userCorrection(low: 180, likely: 180, high: 180)],
            food: review.resolution?.autoPreselect
        )
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: nil,
            correctedPortion: correction
        )
        XCTAssertEqual(action.state, .pending)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)

        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingActionRecord>()), 1)
    }

    func testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto() async throws {
        let barcode = "6901234567892"
        let barcodeHarness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: [
                MealEvidence(kind: .barcode, value: barcode, confidence: 1)
            ]),
            visionProvider: FakeMealVisionProvider(),
            imageConsent: false,
            imageEnabled: true
        )
        let barcodeResult = try await barcodeHarness.service.prepareForAgent(originalData: try fixtureJPEG())
        guard case .textOnlyFallback(let prompt) = barcodeResult else {
            return XCTFail("An unmatched barcode must not fall through with the photo")
        }
        XCTAssertFalse(prompt.contains(barcode))
        XCTAssertTrue(prompt.contains("不要上传这张图片"))

        let openPhotoHarness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: FakeMealVisionProvider(),
            imageConsent: false,
            imageEnabled: true
        )
        let openPhotoResult = try await openPhotoHarness.service.prepareForAgent(originalData: try fixtureJPEG())
        guard case .agentRequest(let request) = openPhotoResult else {
            return XCTFail("Open photo input must enter the same AgentSession path")
        }
        XCTAssertNotNil(request.image)
        XCTAssertTrue(request.mealEvidence.isEmpty)
        XCTAssertTrue(request.userText.contains("多个独立菜品请分别记录"))
        XCTAssertTrue(request.userText.contains("避免重复计量"))
        XCTAssertTrue(request.userText.contains("不要把照片估量说成精确克重"))
    }

    func testNutritionLabelSkipsQwenAndKeepsUnknownMacrosNil() async throws {
        let scanner = FakeMealImageScanner(evidence: [
            MealEvidence(
                kind: .nutritionLabel,
                value: "测试饮料\n每份 250g\n能量 100 kcal\n蛋白质 3g",
                confidence: 0.95
            )
        ])
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: scanner,
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())
        let candidate = try XCTUnwrap(review.resolution?.candidates.first)
        XCTAssertEqual(review.resolution?.autoPreselect?.id, candidate.id)
        XCTAssertTrue(candidate.evidence.contains {
            $0.sourceID == "food-evidence-v2:nutritionLabel" && $0.grade == .label
        })
        XCTAssertFalse(candidate.evidence.contains {
            $0.summary.contains("测试饮料\n每份 250g")
                || ($0.sourceVersion?.contains("测试饮料\n每份 250g") ?? false)
        })
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: candidate.id,
            correctedPortion: try PortionEstimator().estimate(
                evidence: [.userCorrection(low: 250, likely: 250, high: 250)],
                food: candidate
            )
        )

        XCTAssertEqual(review.route, .nutritionLabel)
        XCTAssertTrue(review.clarification?.prompt.contains("份数") == true)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected meal payload")
        }
        XCTAssertFalse(draft.dishes.flatMap(\.evidence).contains {
            $0.summary.contains("测试饮料\n每份 250g")
        })
        XCTAssertNotNil(draft.totalNutrients?.proteinGrams)
        XCTAssertNil(draft.totalNutrients?.fatGrams)
        XCTAssertNil(draft.totalNutrients?.carbohydrateGrams)
        _ = try await harness.confirmation.confirm(action: action)
        let context = ModelContext(harness.container)
        let meal = try XCTUnwrap(context.fetch(FetchDescriptor<MealRecord>()).first)
        XCTAssertNotNil(meal.proteinLikelyG)
        XCTAssertEqual(meal.proteinG, meal.proteinLikelyG ?? -1)
        XCTAssertNil(meal.fatLikelyG)
        XCTAssertNil(meal.carbsLikelyG)
        XCTAssertNil(meal.fatLowG)
        XCTAssertNil(meal.fatHighG)
        XCTAssertNil(meal.carbsLowG)
        XCTAssertNil(meal.carbsHighG)
        XCTAssertEqual(meal.fatG, 0)
        XCTAssertEqual(meal.carbsG, 0)
        let dish = try XCTUnwrap(meal.dishes.first)
        XCTAssertNil(dish.fatLowG)
        XCTAssertNil(dish.fatLikelyG)
        XCTAssertNil(dish.fatHighG)
        XCTAssertNil(dish.carbsLowG)
        XCTAssertNil(dish.carbsLikelyG)
        XCTAssertNil(dish.carbsHighG)
        XCTAssertEqual(dish.estimatedFatG, 0)
        XCTAssertEqual(dish.estimatedCarbsG, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CommittedActionReceiptRecord>()), 1)
    }

    func testValidBarcodeProviderFailureNeverFallsThroughToQwen() async throws {
        let scanner = FakeMealImageScanner(evidence: [
            MealEvidence(kind: .barcode, value: "6901234567892", confidence: 1)
        ])
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: scanner,
            packagedFoodProvider: ThrowingPackagedFoodProvider(),
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true,
            allowsQwenMealVision: true,
            qualityGate: .syntheticContractV1
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .manualDescription)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
    }

    func testLocalOnlyBarcodeScanNeverCallsPackagedFoodProvider() async throws {
        let scanner = FakeMealImageScanner(evidence: [
            MealEvidence(kind: .barcode, value: "6901234567892", confidence: 1)
        ])
        let packaged = CountingPackagedFoodProvider(match: nil)
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: scanner,
            packagedFoodProvider: packaged,
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true,
            allowsRemotePackagedFoodLookup: false
        )

        let result = try await harness.service.prepareForAgent(originalData: try fixtureJPEG())

        guard case .textOnlyFallback = result else {
            return XCTFail("Local Only barcode misses must stay in the local text fallback")
        }
        let packagedLookupCalls = await packaged.callCount()
        XCTAssertEqual(packagedLookupCalls, 0)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
    }

    func testOptionalQwenOpenPhotoRequiresSeparateQwenConsent() async throws {
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: FakeMealVisionProvider(),
            imageConsent: false,
            imageEnabled: true,
            allowsQwenMealVision: true
        )

        do {
            _ = try await harness.service.analyzePhoto(try fixtureJPEG())
            XCTFail("Expected image consent gate")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .mealVisionConsentRequired)
        }
    }

    func testDeepSeekPhotoModeNeverFallsThroughToOptionalQwenVision() async throws {
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true,
            allowsQwenMealVision: false,
            qualityGate: .syntheticContractV1
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .manualDescription)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
    }

    func testLowConfidenceVisionCannotStageFoodIDWithoutUserSelection() async throws {
        let vision = FakeMealVisionProvider(
            observation: MealVisionObservation(
                labels: ["米"],
                preparationHints: [.unknown],
                isOccluded: true,
                modelVersion: "fixture-vl"
            )
        )
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true,
            allowsQwenMealVision: true
        )
        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .qwenVision)
        XCTAssertNil(review.resolution?.autoPreselect)
        XCTAssertNil(review.portion)
        XCTAssertEqual(review.clarification?.kind, .portion)
        XCTAssertGreaterThanOrEqual(review.candidateNames.count, 2)
        XCTAssertNil(review.inferredOilGrams)
        XCTAssertTrue(review.resolution?.candidates.allSatisfy { candidate in
            candidate.entry.licenseStatus == "verified"
                && candidate.entry.sourceID?.isEmpty == false
                && candidate.entry.sourceRecordID?.isEmpty == false
                && !candidate.entry.sourceVersion.isEmpty
                && FoodMassBasis(rawValue: candidate.entry.massBasis ?? "") != nil
        } == true)
        do {
            _ = try await harness.service.stageMeal(review: review, selectedFoodID: nil)
            XCTFail("Expected explicit candidate selection")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .candidateSelectionRequired)
        }

        let selectedCandidate = try XCTUnwrap(review.resolution?.candidates.first)
        let correctedPortion = try PortionEstimator().estimate(
            evidence: [.userCorrection(low: 100, likely: 100, high: 100)],
            food: selectedCandidate
        )
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: selectedCandidate.id,
            correctedPortion: correctedPortion
        )
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected meal payload")
        }
        XCTAssertEqual(draft.dishes.first?.ingredients.first?.foodID, selectedCandidate.entry.localFoodID)
    }

    func testVisionResolutionUsesV2LabelEvidenceAndConfirmedHistory() async throws {
        let scanner = FakeMealImageScanner(evidence: [
            MealEvidence(kind: .nutritionLabel, value: "熟米饭", confidence: 0.92, sourceVersion: "local-ocr")
        ])
        let vision = FakeMealVisionProvider(
            observation: MealVisionObservation(
                labels: ["熟米饭"],
                preparationHints: [.cooked],
                isOccluded: false,
                modelVersion: "fixture-vl"
            )
        )
        let harness = try await MealCaptureHarness(
            scanner: scanner,
            visionProvider: vision,
            confirmedFoodHistory: FakeConfirmedFoodHistory(foodIDs: ["2"]),
            imageConsent: true,
            imageEnabled: true,
            allowsQwenMealVision: true
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .qwenVision)
        let candidate = try XCTUnwrap(review.resolution?.candidates.first {
            $0.entry.localFoodID == "2"
        })
        XCTAssertEqual(candidate.breakdown.confirmedUserHistory, 1)
        XCTAssertTrue(candidate.evidence.contains {
            $0.sourceID == "food-evidence-v2:nutritionLabel" && $0.grade == .label
        })
        XCTAssertTrue(candidate.evidence.contains {
            $0.sourceID == "food-evidence-v2:foodCandidate"
        })
        XCTAssertFalse(candidate.evidence.contains { $0.summary == "熟米饭" })
    }

    func testPortionClarificationMustBeAnsweredAndIsPersistedAsUserEvidence() async throws {
        let vision = FakeMealVisionProvider(
            observation: MealVisionObservation(
                labels: ["熟米饭"],
                preparationHints: [.cooked],
                cookingMethod: "steam",
                containerHint: "bowl",
                portionHint: "约180g",
                isOccluded: false,
                modelVersion: "fixture-vl"
            )
        )
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true,
            allowsQwenMealVision: true
        )
        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.clarification?.kind, .portion)
        let photoPortion = try XCTUnwrap(review.portion)
        XCTAssertEqual(photoPortion.source, .photoWithoutScale)
        XCTAssertFalse(photoPortion.isMeasured)
        XCTAssertEqual(photoPortion.lowGrams, 90, accuracy: 0.001)
        XCTAssertEqual(photoPortion.likelyGrams, 180, accuracy: 0.001)
        XCTAssertEqual(photoPortion.highGrams, 270, accuracy: 0.001)
        do {
            _ = try await harness.service.stageMeal(
                review: review,
                selectedFoodID: nil
            )
            XCTFail("A required portion clarification must not be skipped")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .clarificationAnswerRequired)
        }

        let correction = try PortionEstimator().estimate(
            evidence: [.userCorrection(low: 150, likely: 150, high: 150)],
            food: review.resolution?.autoPreselect
        )
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: nil,
            correctedPortion: correction
        )
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected meal payload")
        }
        let evidence = draft.dishes.flatMap(\.evidence)
        XCTAssertTrue(evidence.contains {
            $0.sourceID == "user-corrected-portion" && $0.grade == .userReported
        })
    }

    func testDisabledQualityGateKeepsOpenPhotoOnManualPath() async throws {
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true,
            qualityGate: MealVisionQualityGate(
                exactAliasAccuracy: 1,
                rawCookedAccuracy: 1,
                top1Accuracy: 0.79,
                top3Accuracy: 1,
                portionCoverage: 1
            )
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .manualDescription)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
    }

    func testDefaultClosedQualityGateRequiresManualFallbackWithoutStaging() async throws {
        let vision = FakeMealVisionProvider()
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: vision,
            imageConsent: true,
            imageEnabled: true,
            qualityGate: .unavailable
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .manualDescription)
        XCTAssertTrue(review.candidateNames.isEmpty)
        do {
            _ = try await harness.service.stageMeal(review: review, selectedFoodID: nil)
            XCTFail("A manual fallback without candidates must not stage a meal")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .candidateSelectionRequired)
        }
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
    }

    private func fixtureJPEG() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw Gate05TestError.fixture
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw Gate05TestError.fixture }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Gate05TestError.fixture }
        return data as Data
    }
}

private enum Gate05TestError: Error { case fixture }

private actor FakeMealImageScanner: MealImageScanning {
    let evidence: [MealEvidence]
    init(evidence: [MealEvidence]) { self.evidence = evidence }
    func scan(imageJPEG: Data) async throws -> [MealEvidence] { evidence }
}

private actor FakeMealVisionProvider: MealVisionProviding {
    let observation: MealVisionObservation
    private var calls = 0

    init(observation: MealVisionObservation = MealVisionObservation(
        labels: ["熟米饭"],
        preparationHints: [.cooked],
        cookingMethod: "steam",
        containerHint: "bowl",
        portionHint: "约180g",
        isOccluded: false,
        modelVersion: "fixture-vl"
    )) {
        self.observation = observation
    }

    func analyze(imageJPEG: Data, locale: Locale) async throws -> MealVisionObservation {
        calls += 1
        return observation
    }

    func analyze(
        imageJPEG: Data,
        locale: Locale,
        serializationGate: @escaping @Sendable (@Sendable () throws -> Data) async throws -> Data
    ) async throws -> MealVisionObservation {
        _ = try await serializationGate { Data() }
        return try await analyze(imageJPEG: imageJPEG, locale: locale)
    }

    func callCount() -> Int { calls }
}

private struct FakePackagedFoodProvider: PackagedFoodProvider {
    let match: PackagedFoodMatch?
    func lookup(barcode: String) async throws -> PackagedFoodMatch? { match }
}

private actor CountingPackagedFoodProvider: PackagedFoodProvider {
    let match: PackagedFoodMatch?
    private var calls = 0

    init(match: PackagedFoodMatch?) { self.match = match }

    func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        calls += 1
        return match
    }

    func callCount() -> Int { calls }
}

private struct ThrowingPackagedFoodProvider: PackagedFoodProvider {
    func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        throw PackagedFoodProviderError.offlineWithoutCache
    }
}

private struct FakeConfirmedFoodHistory: ConfirmedFoodHistoryProviding {
    let foodIDs: Set<String>

    func confirmedFoodIDs(matching label: String) async throws -> Set<String> {
        foodIDs
    }
}

@MainActor
private struct MealCaptureHarness {
    let container: ModelContainer
    let confirmation: ConfirmationCoordinator
    let service: MealCaptureApplicationService

    init(
        scanner: any MealImageScanning,
        packagedFoodProvider: (any PackagedFoodProvider)? = nil,
        visionProvider: any MealVisionProviding,
        confirmedFoodHistory: (any ConfirmedFoodHistoryProviding)? = nil,
        imageConsent: Bool,
        imageEnabled: Bool,
        allowsRemotePackagedFoodLookup: Bool = true,
        allowsQwenMealVision: Bool = false,
        qualityGate: MealVisionQualityGate = .syntheticContractV1
    ) async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let confirmation = ConfirmationCoordinator(
            repository: SwiftDataConfirmationRepository(modelContainer: container),
            writeGate: PersistenceWriteGate(state: .writable)
        )
        let governance = InMemoryProviderGovernanceRepository()
        if imageConsent {
            try await governance.setConsent(
                provider: .qwen,
                dataClass: .mealImage,
                granted: true,
                policyVersion: "fixture"
            )
        }
        let configuration = ProviderConfigurationPreferences()
        configuration.qwenMealVisionEnabled = imageEnabled
        let foodDatabase = try FoodDatabase(seedJSON: Data(Self.seedJSON.utf8))
        self.container = container
        self.confirmation = confirmation
        self.service = MealCaptureApplicationService(
            foodDatabase: foodDatabase,
            scanner: scanner,
            packagedFoodProvider: packagedFoodProvider,
            allowsRemotePackagedFoodLookup: allowsRemotePackagedFoodLookup,
            confirmedFoodHistory: confirmedFoodHistory,
            visionProvider: visionProvider,
            allowsQwenMealVision: allowsQwenMealVision,
            governanceRepository: governance,
            providerConfiguration: configuration,
            usageLedger: ProviderUsageLedger(repository: governance, pricingDescriptorSource: TestPricingDescriptorCatalog.source),
            confirmationCoordinator: confirmation,
            qualityGate: qualityGate
        )
    }

    private static let seedJSON = """
    [
      {"id":2,"name":"米饭(熟)","alias":"熟米饭|白米饭","preparation":"cooked","category":"谷类及制品","edible":100,"energyKcal":116,"proteinG":2.6,"fatG":0.3,"carbohydrateG":25.9,"fiberG":0.3,"sourceID":"fixture-food-composition","sourceRecordID":"rice-cooked","sourceVersion":"fixture-v1","licenseStatus":"verified","sourceRecordJSON":"{\\\"massBasis\\\":\\\"cooked\\\"}"},
      {"id":31,"name":"大米(生)","alias":"生大米|大米","preparation":"raw","category":"谷类及制品","edible":100,"energyKcal":346,"proteinG":7.4,"fatG":0.8,"carbohydrateG":77.9,"fiberG":0.7,"sourceID":"fixture-food-composition","sourceRecordID":"rice-raw","sourceVersion":"fixture-v1","licenseStatus":"verified","sourceRecordJSON":"{\\\"massBasis\\\":\\\"edibleRaw\\\"}"}
    ]
    """

}
