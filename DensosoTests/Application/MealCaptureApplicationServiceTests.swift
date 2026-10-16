import CoreGraphics
import DensosoDomain
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Densoso

@MainActor
final class MealCaptureApplicationServiceTests: XCTestCase {
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
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: nil
        )

        XCTAssertEqual(review.route, .packagedBarcode)
        XCTAssertFalse(review.rawPhotoRetained)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
        XCTAssertEqual(action.state, .pending)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected meal payload")
        }
        XCTAssertFalse(draft.dishes.flatMap(\.evidence).contains {
            $0.sourceID == "user-selected-candidate"
        })
        let context = ModelContext(harness.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
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
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: nil
        )

        XCTAssertEqual(review.route, .nutritionLabel)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected meal payload")
        }
        XCTAssertNotNil(draft.totalNutrients?.proteinGrams)
        XCTAssertNil(draft.totalNutrients?.fatGrams)
        XCTAssertNil(draft.totalNutrients?.carbohydrateGrams)
        _ = try await harness.confirmation.confirm(id: action.id)
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
            qualityGate: .syntheticContractV1
        )

        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .manualDescription)
        let visionCalls = await vision.callCount()
        XCTAssertEqual(visionCalls, 0)
    }

    func testOpenPhotoRequiresSeparateImageConsent() async throws {
        let harness = try await MealCaptureHarness(
            scanner: FakeMealImageScanner(evidence: []),
            visionProvider: FakeMealVisionProvider(),
            imageConsent: false,
            imageEnabled: true
        )

        do {
            _ = try await harness.service.analyzePhoto(try fixtureJPEG())
            XCTFail("Expected image consent gate")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .mealVisionConsentRequired)
        }
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
            imageEnabled: true
        )
        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.route, .qwenVision)
        XCTAssertNil(review.resolution?.autoPreselect)
        XCTAssertGreaterThanOrEqual(review.candidateNames.count, 2)
        do {
            _ = try await harness.service.stageMeal(review: review, selectedFoodID: nil)
            XCTFail("Expected explicit candidate selection")
        } catch {
            XCTAssertEqual(error as? MealCaptureApplicationError, .candidateSelectionRequired)
        }

        let selectedCandidate = try XCTUnwrap(review.resolution?.candidates.first)
        let action = try await harness.service.stageMeal(
            review: review,
            selectedFoodID: selectedCandidate.id
        )
        guard case .meal(let draft) = action.payload else {
            return XCTFail("Expected meal payload")
        }
        XCTAssertEqual(draft.dishes.first?.ingredients.first?.foodID, selectedCandidate.entry.localFoodID)
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
            imageEnabled: true
        )
        let review = try await harness.service.analyzePhoto(try fixtureJPEG())

        XCTAssertEqual(review.clarification?.kind, .portion)
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

    func callCount() -> Int { calls }
}

private struct FakePackagedFoodProvider: PackagedFoodProvider {
    let match: PackagedFoodMatch?
    func lookup(barcode: String) async throws -> PackagedFoodMatch? { match }
}

private struct ThrowingPackagedFoodProvider: PackagedFoodProvider {
    func lookup(barcode: String) async throws -> PackagedFoodMatch? {
        throw PackagedFoodProviderError.offlineWithoutCache
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
        imageConsent: Bool,
        imageEnabled: Bool,
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
            visionProvider: visionProvider,
            governanceRepository: governance,
            providerConfiguration: configuration,
            usageLedger: ProviderUsageLedger(repository: governance),
            confirmationCoordinator: confirmation,
            qualityGate: qualityGate
        )
    }

    private static let seedJSON = """
    [
      {"id":2,"name":"米饭(熟)","alias":"熟米饭|白米饭","preparation":"cooked","category":"谷类及制品","edible":100,"energyKcal":116,"proteinG":2.6,"fatG":0.3,"carbohydrateG":25.9,"fiberG":0.3},
      {"id":31,"name":"大米(生)","alias":"生大米|大米","preparation":"raw","category":"谷类及制品","edible":100,"energyKcal":346,"proteinG":7.4,"fatG":0.8,"carbohydrateG":77.9,"fiberG":0.7}
    ]
    """
}
