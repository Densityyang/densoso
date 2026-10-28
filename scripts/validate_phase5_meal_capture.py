#!/usr/bin/env python3
"""Validate Gate 5 meal-capture contracts using explicit public fixture paths."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require_text(path: Path, needles: list[str], errors: list[str]) -> str:
    if not path.is_file():
        errors.append(f"missing {path.relative_to(ROOT)}")
        return ""
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            errors.append(f"{path.relative_to(ROOT)} is missing {needle}")
    return text


def load_json(relative: str, errors: list[str]):
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"missing {relative}")
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        errors.append(f"invalid JSON {relative}: {error}")
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    args = parser.parse_args()
    errors: list[str] = []

    resolver = require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/FoodResolver.swift",
        [
            "0.60 * lexicalMatch", "0.15 * preparationCompatibility",
            "0.10 * categoryCompatibility", "0.10 * sourceQuality",
            "0.05 * confirmedUserHistory", "automaticThreshold = 0.85",
            "automaticMargin = 0.12", "Array(candidates.prefix(3))",
        ],
        errors,
    )
    if "import SwiftData" in resolver or "import Vision" in resolver:
        errors.append("FoodResolver must remain Foundation-only")

    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/PortionEstimator.swift",
        [
            "approximateGrams", "* 0.9", "* 1.1", "packageServing",
            "0.95", "1.05", "minimumHalfWidth = 0.30",
            "minimumHalfWidth = 0.50", "minimumHalfWidth = 0.65",
            "isMeasured: false", "userCorrection", "case modelEstimate", "1.65",
            "AlgorithmVersions.portionEstimator",
        ],
        errors,
    )
    meal_estimator = require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/MealEstimator.swift",
        [
            "isCookedComposite", "hasExplicitOil", "oilIngredient",
            "return nil", "foodID = selectedCandidate?.entry.localFoodID",
            "AlgorithmVersions.mealEstimator",
        ],
        errors,
    )
    if "resolution.candidates.first" in meal_estimator:
        errors.append("MealEstimator must not use the first unresolved candidate as likely truth")
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/MealEvidence.swift",
        ["relativeWidth > 0.65", "expectedEnergyRangeReduction >= 0.20", "selectOne"],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/MealQuantityEvidence.swift",
        [
            "case exactGrams", "case household", "case count", "case packageServing",
            "case photoEstimate", "case unknown", "validatedUserReportedGrams",
            "validatedPackageGramsPerServing", "allowLowConfidenceModelEstimate",
            "missingPortionEvidence",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/ExplicitUserGramsParser.swift",
        ["exactGrams(in userText", "hasUncertainContext", "hasAlternativeGramAmount"],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/CaloriePresentationPolicy.swift",
        [
            "relativeWidth <= 0.35", "relativeWidth <= 0.65", "needsClarification",
            "AlgorithmVersions.calorieAccounting",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/HealthDomainDrafts.swift",
        ["var caloriePresentation: CaloriePresentation?", "totalNutrients?.energyKcal"],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/AlgorithmVersions.swift",
        [
            'public static let calorieAccounting = "calorie-accounting-v3"',
            'public static let mealEstimator = "meal-estimator-v2"',
            'public static let portionEstimator = "portion-estimator-v2"',
        ],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Sources/DensosoDomain/ActionPayload.swift",
        ["presentation.likelyKcal", "presentation.confidence.displayName", "热量暂不可用"],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Tests/DensosoDomainTests/MealQuantityEvidenceTests.swift",
        [
            "testCaloriePresentationUsesLikelyPointAndRelativeWidthThresholds",
            "testMealSummaryCarriesLikelyValueAndTextConfidenceWithoutFalseZero",
            "testV2MealAlgorithmVersionsAreExplicit",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Views/Components/FoodConfirmationCard.swift",
        [
            "likelyText = \"约 \\(presentation.likelyKcal) kcal\"",
            "detailsTitle = \"估算区间详情\"",
            "rangeDetailsText = \"热量范围：",
            "DisclosureGroup {",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/Application/MealCalorieSummaryPresentationTests.swift",
        (
            'XCTAssertEqual(summary.detailsTitle, "估算区间详情")',
            'XCTAssertEqual(summary.rangeDetailsText, "热量范围：100–1000 kcal")',
        ),
        errors,
    )

    log_meal = require_text(
        ROOT / "Densoso/Agent/Tools/LogMealTool.swift",
        [
            "FoodResolver", "PortionEstimator", "MealEstimator", "ambiguousFood",
            "context.currentMealHasImage()", "ingredient.quantityEvidence.kind == .photoEstimate",
        ],
        errors,
    )
    if "rankedSearch" in log_meal or "CookingCoefficientTable" in log_meal:
        errors.append("log_meal retains a silent first-match or whole-dish coefficient path")
    if "resolution.candidates.first" in log_meal:
        errors.append("log_meal still selects the first food match implicitly")
    if '"amountGrams"' in log_meal or '"notedOilG"' in log_meal:
        errors.append("log_meal must not accept model-supplied exact ingredient or oil grams")
    require_text(
        ROOT / "DensosoTests/Application/LogMealQuantityEvidenceTests.swift",
        [
            "testExactGramsUsesCurrentUserTextInsteadOfModelClaim",
            "testUnverifiedModelGramClaimRequestsClarificationWithoutStaging",
            "testPhotoEstimateWithoutCurrentImageRequestsPortionEvidence",
            "testAnswerAfterOneClarificationStagesWideEstimateWithoutAskingAgain",
            "testUserStillUncertainAfterClarificationStagesLowConfidenceEstimateWithoutSecondQuestion",
            "testNewUnrelatedFoodDoesNotInheritPreviousMealClarification",
            "testPackageServingRequiresLocalUserOrLabelGrams",
            "testPackageServingMassIsNotReusedAcrossMixedIngredients",
            "testUnknownPortionAsksAtMostOneQuestionAndNeverStagesMeal",
            "testUnknownFoodIdentityDoesNotReceiveInventedCalories",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/Application/ToolSchemaTests.swift",
        ("testLogMealRequiresRealNestedArrays", 'legacyIngredient["amountGrams"] = .number(150)'),
        errors,
    )

    require_text(
        ROOT / "Densoso/Infrastructure/Vision/PhotoEvidenceSanitizer.swift",
        [
            "maximumPixelSize: Int = 1_280", "compressionQuality: CGFloat = 0.75",
            "kCGImageSourceThumbnailMaxPixelSize", "kCGImageMetadataShouldExcludeGPS",
            "kCGImageMetadataShouldExcludeXMP",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Infrastructure/Vision/CameraImageOrientationNormalizer.swift",
        [
            "case .right: .right", "case .leftMirrored: .leftMirrored",
            "oriented(forExifOrientation:", "CGImageDestinationAddImage(destination, uprightImage, nil)",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Infrastructure/Vision/BarcodeAndLabelScanner.swift",
        ["VNDetectBarcodesRequest", "VNRecognizeTextRequest", "isValidGTIN", "orientation:"],
        errors,
    )
    require_text(
        ROOT / "Densoso/Infrastructure/LLM/QwenMealVisionProvider.swift",
        [
            'model = "qwen3.7-flash-2026-07-15"',
            "requiredCapabilities: Set<ProviderCapability> = [.vision, .structuredOutput]",
            'type: "image_url"', '"data:image/jpeg;base64,', 'type = "json_schema"', "allowedKeys",
            "responseModel == Self.model",
            "schemaViolation(path: \"visionObservation\")",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/Infrastructure/LLM/QwenMealVisionProviderContractTests.swift",
        [
            "testPinnedQwen37SnapshotUsesImageAndStructuredObservationContract",
            "testRollingQwen37AliasDoesNotSatisfyPinnedSnapshot",
            '"qwen3.7-flash-2026-07-15"',
            '"json_schema"',
            '"additionalProperties"] as? Bool, false',
        ],
        errors,
    )
    application_service = require_text(
        ROOT / "Densoso/Application/Meal/MealCaptureApplicationService.swift",
        [
            "rawPhotoRetained: false", "dataClass: .mealImage", "allowsOpenPhoto",
            "stageMeal", "confirmationCoordinator.stage", "packagedBarcode",
            "nutritionLabel", "qwenVision", "manualDescription",
            "FoodResolverV2(catalog:", "FoodResolutionV2Query(",
            "confirmedHistoryFoodIDs:", "barcodeMatchedFoodID:",
            "massBasis: nil",
            "sourceBackedMassBasis(for: selected.entry)",
            "本地识别到营养标签",
            "enum MealCapturePreparation",
            "case agentRequest(MultimodalModelRequest)",
            "case localReview(MealCaptureReview)",
            "case textOnlyFallback(String)",
            "return .localReview(review)",
            "return .textOnlyFallback(",
            "return .agentRequest(try MultimodalModelRequest(",
            "consumedPortionClarification(canConvertServingCount:",
        ],
        errors,
    )
    if "FoodResolver(catalog:" in application_service or "FoodResolutionQuery(" in application_service:
        errors.append("photo candidate routes must use the shared FoodResolverV2 contract")
    if "qualityGate: MealVisionQualityGate = .unavailable" not in application_service:
        errors.append("optional Qwen photo-review quality gate must default closed")
    if "if barcode != nil { return manualReview" not in application_service:
        errors.append("valid barcode miss/error must not fall through to Qwen vision")
    require_text(
        ROOT / "Densoso/Persistence/Schemas/DensosoSchemaV3.swift",
        ["var proteinLikelyG: Double?", "var fatLikelyG: Double?", "var carbsLikelyG: Double?"],
        errors,
    )
    require_text(
        ROOT / "project.yml",
        ["INFOPLIST_KEY_NSCameraUsageDescription", "evals/gate05/manifest.json"],
        errors,
    )
    require_text(
        ROOT / "Densoso/Views/SettingsScreen.swift",
        ["isOn: .constant(false)", "dataClass: .mealImage"],
        errors,
    )
    require_text(
        ROOT / "Densoso/Views/MealCaptureSheet.swift",
        [
            "case .localReview(let review)",
            "prepareForAgent(originalData: originalData)",
            "stageLocalReview(localReview)",
            "onLocalPendingAction(action)",
            "Picker(\"选择最接近的候选\"",
            "TextField(portionAnswerPrompt, text: $portionAnswerText)",
            "MultimodalModelRequest(userText: textOnlyFallback)",
            "packagePortion.source == .packageServing",
            "userNote: supplementalText",
        ],
        errors,
    )
    require_text(
        ROOT / "Densoso/Application/Meal/MealCaptureApplicationService.swift",
        [
            "clarificationAnswerRequired", "user-corrected-portion",
            "user-clarified-oil", "auto-preselected-candidate",
        ],
        errors,
    )

    catalog = load_json("evals/gate05/food-catalog.json", errors)
    resolution = load_json("evals/gate05/food-resolution.json", errors)
    portions = load_json("evals/gate05/portion-reference.json", errors)
    manifest = load_json("evals/gate05/manifest.json", errors)
    resolution_count = sum(len(group.get("queries", [])) for group in (resolution or {}).get("groups", []))
    portion_count = sum(len(group.get("samples", [])) for group in (portions or {}).get("groups", []))
    if len(catalog or []) < 10:
        errors.append("Gate 5 synthetic catalog must contain at least 10 foods")
    if resolution_count != 100:
        errors.append(f"Gate 5 resolution set has {resolution_count} cases, expected 100")
    if portion_count != 50:
        errors.append(f"Gate 5 portion set has {portion_count} cases, expected 50")
    if manifest:
        if manifest.get("protectedOCRSourceUsed") is not False:
            errors.append("Gate 5 manifest must state protected OCR was not used")
        if manifest.get("fieldMeasurementClaimed") is not False:
            errors.append("synthetic portion fixtures cannot claim field measurements")
        if manifest.get("fieldBenchmark") != {
            "status": "NOT_MEASURED",
            "reason": "NO_LABELED_FIELD_DATA",
        }:
            errors.append("Gate 5 field benchmark must remain NOT_MEASURED without labeled field data")
        photo_gate = manifest.get("openPhotoFeatureGate")
        if (
            not isinstance(photo_gate, str)
            or "optional Qwen review remains disabled without measured field calibration" not in photo_gate
            or "default DeepSeek Agent photo flow uses separate consent and explicit user send" not in photo_gate
        ):
            errors.append("Gate 5 must distinguish the optional Qwen review gate from the default DeepSeek Agent photo flow")
        thresholds = manifest.get("thresholds", {})
        expected = {
            "exactAliasAccuracy": 1.0,
            "rawCookedAccuracy": 1.0,
            "minimumTop1Accuracy": 0.8,
            "minimumTop3Accuracy": 0.9,
            "minimumPortionCoverage": 0.8,
            "maximumOutsideRate": 0.2,
        }
        for key, value in expected.items():
            if thresholds.get(key) != value:
                errors.append(f"Gate 5 threshold {key} must equal {value}")
        hashes = manifest.get("sha256", {})
        for filename in ("food-catalog.json", "food-resolution.json", "portion-reference.json"):
            path = ROOT / "evals/gate05" / filename
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if hashes.get(filename) != actual:
                errors.append(f"Gate 5 manifest hash mismatch for {filename}")

    fixture_paths = [
        "DensosoTests/Fixtures/Gate05/Providers/Qwen/qwen3.7-flash-2026-07-15-response.json",
        "DensosoTests/Fixtures/Gate05/Providers/Qwen/qwen3.7-flash-2026-07-15-forbidden-food-id.json",
    ]
    for relative in fixture_paths:
        load_json(relative, errors)

    test_files = [
        "DensosoTests/Application/Gate05EvaluationTests.swift",
        "DensosoTests/Application/MealCaptureApplicationServiceTests.swift",
        "DensosoTests/Infrastructure/LLM/QwenMealVisionProviderContractTests.swift",
        "Packages/DensosoDomain/Tests/DensosoDomainTests/MealResolutionTests.swift",
        "Packages/DensosoDomain/Tests/DensosoDomainTests/FoodResolutionV2Tests.swift",
    ]
    for relative in test_files:
        if not (ROOT / relative).is_file():
            errors.append(f"missing {relative}")
    require_text(
        ROOT / "DensosoTests/Application/MealCaptureApplicationServiceTests.swift",
        [
            "testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount",
            "testDefaultClosedQualityGateRequiresManualFallbackWithoutStaging",
            "testPortionClarificationMustBeAnsweredAndIsPersistedAsUserEvidence",
            "testBarcodeMatchSkipsQwenAndStillCreatesOnlyPendingAction",
            "testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction",
            "testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion",
            "testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto",
            "testNutritionLabelSkipsQwenAndKeepsUnknownMacrosNil",
            "testLowConfidenceVisionCannotStageFoodIDWithoutUserSelection",
            "testVisionResolutionUsesV2LabelEvidenceAndConfirmedHistory",
            "XCTAssertEqual(review.resolution?.autoPreselect?.id, candidate.id)",
            "$0.summary.contains(\"6901234567892\")",
            "$0.summary.contains(\"测试饮料\\n每份 250g\")",
            "food-evidence-v2:nutritionLabel",
            "food-evidence-v2:foodCandidate",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Tests/DensosoDomainTests/FoodResolutionV2Tests.swift",
        [
            "testAliasAndCategoryHaveSeparateScoreAxes",
            "testMassBasisAndPreparationCompatibilityRankCookedFood",
            "testConfirmedFoodHistoryContributesIndependentV2Score",
            "testLocalLabelAndVisualEvidenceScoreCandidateWithoutReturningRawText",
            "testBarcodeMatchCanResolveLabelWithoutChangingConfirmationRequirement",
            "testCloseCandidatesStayUnresolvedAndRequireConfirmation",
            "testShortASCIINameInsideAnUnrelatedLabelDoesNotBoostEvidence",
            "testV2ScoreAxesSurviveMealResolverAndDraftBridges",
        ],
        errors,
    )
    require_text(
        ROOT / "Packages/DensosoDomain/Tests/DensosoDomainTests/MealResolutionTests.swift",
        ["testPortionEvidenceIntersectsEqualPriorityAndRetainsConflicts"],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/PhotoEvidenceSanitizerTests.swift",
        [
            "testCameraImageOrientationIsAppliedBeforeSanitizing",
            "testConfiguredJPEGQualitiesProduceDecodableBoundedImages",
            "kCGImagePropertyExifMakerNote",
            "private func exifPayload()",
            "gate05-xmp-marker",
            "appendUInt16LittleEndian",
        ],
        errors,
    )
    require_text(
        ROOT / "DensosoTests/BarcodeAndLabelScannerTests.swift",
        [
            "testUPCEIsExpandedAndValidatedUsingItsDedicatedFormat",
            "testBarcodeCandidatesAreOrderedByConfidenceAndOnlyASCIIEncodedDigitsAreAccepted",
        ],
        errors,
    )
    require_text(
        ROOT / "docs/gates/gate-05-meal-capture.md",
        [
            "NOT_MEASURED",
            "optional Qwen review path",
            "default open-photo route",
            "DeepSeek multimodal Agent path",
            "qwen3.7-flash-2026-07-15",
            "strict JSON Schema",
            "response contract",
            "rolling aliases are rejected",
            "this meal-vision adapter does not expose or execute tool calls",
            "Non-optional V3 point mirrors may contain",
            "aggregates are outside this gate's accuracy claim",
            "FoodResolverV2",
            "V2 scoring keeps lexical, alias, preparation, mass-basis, category, history and evidence as independent axes.",
            "Candidate evidence summaries do not copy raw OCR text.",
            "The seven V2 score axes are retained with the pending meal draft",
        ],
        errors,
    )

    require_text(
        ROOT / ".github/workflows/build.yml",
        [
            "meal-capture:", "needs: speech", "gate-05-meal-capture",
            "validate_phase5_meal_capture.py", "Gate05MealCaptureTests.xcresult",
            "gate-05-meal-capture-results", "gate05-execution-summary.json",
            "continue-on-error: true", "Record Gate 5 execution status",
            "food-catalog.json", "Fixtures/Gate05/Providers/Qwen",
            "swift test --package-path Packages/DensosoDomain 2>&1 | tee gate05-domain.log",
            "-only-testing:DensosoTests/MealCaptureApplicationServiceTests",
        ],
        errors,
    )

    report = {
        "status": "fail" if errors else "pass",
        "statusScope": "static contracts and synthetic fixtures only",
        "failedAssertions": len(errors),
        "errors": errors,
        "catalogItems": len(catalog),
        "resolutionCases": resolution_count,
        "portionReferences": portion_count,
        "providerFixtures": len(fixture_paths),
        "liveNetworkCalls": 0,
        "fieldMeasurementClaimed": (manifest or {}).get("fieldMeasurementClaimed"),
        "fieldBenchmark": (manifest or {}).get(
            "fieldBenchmark",
            {"status": "NOT_MEASURED", "reason": "NO_LABELED_FIELD_DATA"},
        ),
        "protectedOCRSourceUsed": (manifest or {}).get("protectedOCRSourceUsed"),
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Phase 5 meal-capture static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
