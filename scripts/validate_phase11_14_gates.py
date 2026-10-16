#!/usr/bin/env python3
"""Validate focused Gate 11–14 scope and keep device acceptance manual."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_text(relative: str, errors: list[str]) -> str:
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"missing {relative}")
        return ""
    return path.read_text(encoding="utf-8")


def require(relative: str, needles: tuple[str, ...], errors: list[str]) -> str:
    content = read_text(relative, errors)
    for needle in needles:
        if needle not in content:
            errors.append(f"{relative} is missing {needle}")
    return content


def gate_contract(gate: int, errors: list[str]) -> str:
    if gate == 11:
        require(
            "docs/gates/gate-11-ai-native-health-loop.md",
            (
                "Gate 11",
                "historical effective profiles",
                "HealthRepositoryTests.testInsertAndDeleteReprojectsTheSameDay",
                "CaloricEnergySemanticsTests.testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics",
                "HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches",
                "DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState",
                "DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
                "does not prove access to a real person's HealthKit data",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/EffectiveProfileTests.swift",
            ("testResolvesProfileRevisionAtHistoricalDate",),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/WeightTimelineTests.swift",
            ("testUsesLatestTrustedObservationNotLaterThanRequestedDate",),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/HealthStateTests.swift",
            ("testMissingSleepVitalsAndTrainingLoadRemainUnknown",),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/DailyLoopSnapshotTests.swift",
            ("testSnapshotSupportsUnavailableOptionalSummaries",),
            errors,
        )
        require(
            "DensosoTests/HealthRepositoryTests.swift",
            ("testInsertAndDeleteReprojectsTheSameDay",),
            errors,
        )
        require(
            "DensosoTests/Application/DailyLoopSnapshotCompositionTests.swift",
            ("testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary",),
            errors,
        )
        return "healthkit-to-daily-loop"

    if gate == 12:
        require(
            "docs/gates/gate-12-multimodal-agent.md",
            (
                "Gate 12",
                "passes a bounded `MultimodalModelRequest` to that same `AgentSession`",
                "must separately consent to DeepSeek meal-image upload",
                "OCR/evidence text is not persisted",
                "Confirmation remains required",
                "supplemental text in the same user turn",
                "same AgentSession",
                "a text-only or Qwen provider is rejected without fallback",
            ),
            errors,
        )
        chat = require(
            "Densoso/Views/ChatScreen.swift",
            (
                "inputText = speech.transcribedText",
                "dependencies.agentSession.send(userText:",
                "MealCaptureSheet { request in",
                "request.includingSupplementalText(inputText)",
                "multimodalRequest: multimodalRequest",
                "path != .cloudDeepSeek",
            ),
            errors,
        )
        photo = require(
            "Densoso/Views/MealCaptureSheet.swift",
            (
                "let onSendToAgent: (MultimodalModelRequest) -> Void",
                "prepareForAgent(originalData: originalData)",
                "onSendToAgent(preparedRequest)",
                "照片会先在本机缩放并移除元数据",
                "图像字节不会保存到对话历史",
            ),
            errors,
        )
        require(
            "Densoso/Application/Meal/MealCaptureApplicationService.swift",
            ("func prepareForAgent(", "photoSanitizer.sanitize", "scanner.scan(imageJPEG: sanitized)"),
            errors,
        )
        session = require(
            "Densoso/Agent/AgentSession.swift",
            (
                "func send(multimodalRequest: MultimodalModelRequest",
                "provider.descriptor.capabilities.contains(.vision)",
                "dataClass: .mealImage",
                "requestSnapshot.containsTransientImage",
                "AgentError.transientImageRequired",
                "case .reasoning, .image: return false",
                "withoutTransientImages",
                "func currentMealImageEvidence()",
            ),
            errors,
        )
        if "AgentError.transientImageRequired" in session and "throw AgentError.transientImageRequired" not in session:
            errors.append("interrupted image requests must fail closed before provider routing")
        require(
            "Densoso/Persistence/Schemas/DensosoSchemaV5.swift",
            ("var containsTransientImage: Bool = false",),
            errors,
        )
        multimodal_request = require(
            "Densoso/Infrastructure/LLM/LLMTypes.swift",
            (
                "struct MultimodalModelRequest: Sendable",
                "static let maximumJPEGBytes = 5_000_000",
                "mealEvidence.prefix(Self.maximumMealEvidenceCount)",
            ),
            errors,
        )
        if "struct MultimodalModelRequest: Codable" in multimodal_request:
            errors.append("transient image requests must not be Codable or persisted")
        schema_v5 = read_text("Densoso/Persistence/Schemas/DensosoSchemaV5.swift", errors)
        agent_request_model = schema_v5.split("@Model final class DailyCheckInRecord", 1)[0]
        for forbidden in ("imageJPEG", "base64Data", "ocrText", "mealEvidence"):
            if forbidden in agent_request_model:
                errors.append(f"AgentRequestRecord must not persist {forbidden}")
        require(
            "Densoso/Infrastructure/Persistence/SwiftDataAgentRepository.swift",
            ("existing.containsTransientImage && !containsTransientImage", "requestMediaMismatch"),
            errors,
        )
        require(
            "Densoso/Agent/Tools/LogMealTool.swift",
            (
                "context.currentMealImageEvidence()",
                "本机图像线索已附加，提取文本未保存",
            ),
            errors,
        )
        require(
            "Densoso/Views/SettingsScreen.swift",
            (
                'Toggle("同意向 DeepSeek 上传处理后的餐食照片"',
                'dataClass: .mealImage',
                "deepseek-sanitized-meal-image-v1",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/AgentCoordinatorTests.swift",
            (
                "testRealRoundAndToolCountsAndPendingAction",
                "testProviderReasoningContinuesInMemoryButIsNeverPersisted",
                "testCloudProviderRequiresExplicitConsent",
                "testNinthToolCallStopsRequest",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/AgentRequestResumeTests.swift",
            ("testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage",),
            errors,
        )
        require(
            "DensosoTests/Infrastructure/LLM/DeepSeekProviderContractTests.swift",
            ("testResponsesAPIRequestAndStreamingToolContract", "testImageStructuredOutputAndStatelessToolHistoryEncoding"),
            errors,
        )
        require(
            "DensosoTests/Infrastructure/LLM/QwenASRProviderContractTests.swift",
            ("testOpenAICompatibleAudioRequestAndResponseContract",),
            errors,
        )
        require(
            "DensosoTests/Infrastructure/LLM/QwenMealVisionProviderContractTests.swift",
            ("testImageRequestAndRestrictedObservationContract",),
            errors,
        )
        require(
            "DensosoTests/Application/SpeechCaptureStateMachineTests.swift",
            ("testLocalFailureWithCapturedAudioUsesQwenOnceAndDeletesTemporaryAudio",),
            errors,
        )
        require(
            "DensosoTests/Application/MealCaptureApplicationServiceTests.swift",
            (
                "testOpenPhotoRequiresSeparateImageConsent",
                "testLowConfidenceVisionCannotStageFoodIDWithoutUserSelection",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/MultimodalAgentImageTests.swift",
            (
                "testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence",
                "includingSupplementalText(supplementalText)",
                "XCTAssertEqual(userMessages.count, 1)",
                "testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget",
                "testImageRequiresVisionCapabilityAndSeparateMealImageConsent",
                "PRIVATE-OCR-EVIDENCE-MUST-NOT-PERSIST",
                "XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 0)",
                "transientImageRequired",
            ),
            errors,
        )
        if "AgentSession" not in session or "MultimodalModelRequest" not in chat or "onSendToAgent" not in photo:
            errors.append("text, voice and image must all enter AgentSession")
        return "multimodal-agent"

    if gate == 13:
        require(
            "docs/gates/gate-13-energy-accounting.md",
            (
                "Gate 13",
                "observed basal-plus-active expenditure",
                "explicit-profile fallback",
                "historical effective profile/weight selection",
                "likely-range meal estimates",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/EnergyAccountingTests.swift",
            (
                "testObservedExpenditureUsesBasalPlusActiveExactlyOnce",
                "testMissingHealthKitComponentUsesExplicitProfileEstimate",
                "testMissingProfileOrEffectiveWeightDoesNotInventExpenditure",
            ),
            errors,
        )
        require(
            "DensosoTests/CaloricEnergySemanticsTests.swift",
            (
                "testMeasuredActiveEnergyIsNotAddedToWorkoutEnergy",
                "testWorkoutPresenceDoesNotChangeEstimatedActiveEnergyFallback",
                "testMissingEffectiveProfileDoesNotInventEnergyExpenditure",
            ),
            errors,
        )
        require(
            "DensosoTests/CalorieEstimatorTests.swift",
            ("testExplicitOilIsAddedOnceWithoutCookingMultiplier", "testInferredOilProducesAnHonestInterval"),
            errors,
        )
        return "energy-accounting"

    require(
        "docs/gates/gate-14-watch-daily-loop.md",
        (
            "Gate 14",
            "daily snapshot summaries",
            "offline replay deduplication",
            "arrival ordering",
            "TrainingPlanDraftTests",
            "goal, location, intensity, and reason details",
            "manual Gate 15",
            "Simulator evidence does not prove Watch pairing",
        ),
        errors,
    )
    require(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/DailyLoopSnapshotTests.swift",
        ("testSnapshotRoundTripsStateGuidanceAndActionSummaries",),
        errors,
    )
    require(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/TrainingPlanDraftTests.swift",
        ("testMultiDayPlanAcceptsWorkoutAndRestDays", "testRestDayCannotCarryWorkoutInstructions"),
        errors,
    )
    require(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/WatchMessageOutboxTests.swift",
        (
            "testHundredOfflineMessagesRemainOrderedAndDuplicateReplaysDoNotAddRows",
            "testAcceptedAcknowledgementRemovesMessageAfterPhonePersistsItsReceipt",
        ),
        errors,
    )
    require(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/WatchWorkoutCoordinatorTests.swift",
        ("testLifecyclePreservesLogicalSessionAcrossPauseAndResume",),
        errors,
    )
    require(
        "DensosoTests/WatchMessageInboxStoreTests.swift",
        (
            "testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder",
            "testOutOfOrderMessagesAreReturnedInDurableArrivalOrder",
        ),
        errors,
    )
    require(
        "DensosoTests/Application/DailyLoopSnapshotCompositionTests.swift",
        (
            "testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
            "testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary",
        ),
        errors,
    )
    require(
        "Densoso/Application/DailyLoop/DailyLoopSnapshotService.swift",
        ("case .trainingPlan(_) = action.payload", "requiresPhoneReview: requiresPhoneReview"),
        errors,
    )
    require(
        "DensosoTests/TrainingPlanSchedulingServiceTests.swift",
        (
            "testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry",
            "testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays",
        ),
        errors,
    )
    require(
        "DensosoTests/TrainingPlanScheduleQueryTests.swift",
        ("testGetScheduleExpandsConfirmedTrainingPlanForRequestedDayIncludingRestDay",),
        errors,
    )
    require(
        "DensosoTests/Application/AgentCoordinatorTests.swift",
        ("testOfflineWatchTranscriptSurvivesFailureResumesSameDraftAndConfirmsOnce",),
        errors,
    )
    coordinator = require(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
        ("func activate()", "resumePendingCommands()", "func refreshApplicationContext()", "makeTodaySnapshot()"),
        errors,
    )
    if "resumePendingCommands()" not in coordinator:
        errors.append("Watch activation must restore durable pending commands")
    require(
        "Densoso/Infrastructure/Persistence/SwiftDataAgentRepository.swift",
        (
            "ConfirmedTrainingPlanEntry.decode(notes: event.notes)",
            "String(session.reason.prefix(240))",
            "目标：",
            "地点：",
            "建议强度：",
            "details.joined(separator: \"；\").prefix(600)",
            "ConfirmedWorkoutPlanEntry.decode(notes: event.notes) == nil",
        ),
        errors,
    )
    return "watch-daily-loop"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gate", type=int, choices=(11, 12, 13, 14), required=True)
    parser.add_argument("--report", default="")
    args = parser.parse_args()
    errors: list[str] = []

    workflow = read_text(".github/workflows/build.yml", errors)
    gate_jobs = {
        11: (
            "gate-11-ai-native-health-loop",
            (
                "--filter EffectiveProfileTests",
                "--filter WeightTimelineTests",
                "--filter HealthStateTests",
                "--filter DailyLoopSnapshotTests",
                "-only-testing:DensosoTests/HealthRepositoryTests/testInsertAndDeleteReprojectsTheSameDay",
                "-only-testing:DensosoTests/CaloricEnergySemanticsTests/testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays",
            ),
        ),
        12: (
            "gate-12-multimodal-agent",
            (
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testImageRequiresVisionCapabilityAndSeparateMealImageConsent",
                "-only-testing:DensosoTests/DeepSeekProviderContractTests/testImageStructuredOutputAndStatelessToolHistoryEncoding",
                "-only-testing:DensosoTests/QwenASRProviderContractTests/testOpenAICompatibleAudioRequestAndResponseContract",
                "-only-testing:DensosoTests/QwenMealVisionProviderContractTests/testImageRequestAndRestrictedObservationContract",
                "-only-testing:DensosoTests/AgentRequestResumeTests/testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage",
            ),
        ),
        13: (
            "gate-13-energy-accounting",
            (
                "--filter EnergyAccountingTests",
                "-only-testing:DensosoTests/CaloricEnergySemanticsTests/testMeasuredActiveEnergyIsNotAddedToWorkoutEnergy",
                "-only-testing:DensosoTests/CalorieEstimatorTests/testInferredOilProducesAnHonestInterval",
            ),
        ),
        14: (
            "gate-14-watch-daily-loop",
            (
                "--filter TrainingPlanDraftTests",
                "--filter WatchMessageOutboxTests",
                "--filter WatchWorkoutCoordinatorTests",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays",
                "-only-testing:DensosoTests/TrainingPlanScheduleQueryTests/testGetScheduleExpandsConfirmedTrainingPlanForRequestedDayIncludingRestDay",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder",
                "-only-testing:DensosoTests/AgentCoordinatorTests/testOfflineWatchTranscriptSurvivesFailureResumesSameDraftAndConfirmsOnce",
            ),
        ),
    }
    job_name, selectors = gate_jobs[args.gate]
    match = re.search(
        rf"^  {re.escape(job_name)}:\n(?P<section>.*?)(?=^  [a-z0-9_-]+:|\Z)",
        workflow,
        flags=re.MULTILINE | re.DOTALL,
    )
    job_section = match.group("section") if match else ""
    expected_dependency = {
        11: "needs: final-acceptance",
        12: "needs: gate-11-ai-native-health-loop",
        13: "needs: gate-12-multimodal-agent",
        14: "needs: gate-13-energy-accounting",
    }[args.gate]
    if not job_section or expected_dependency not in job_section:
        errors.append(f"workflow must define {job_name} after its preceding gate")
    for selector in selectors:
        if selector not in job_section:
            errors.append(f"{job_name} must run focused contract {selector}")
    if "gate-15-real-device-acceptance:" in workflow or "gate-16-final-release-acceptance:" in workflow:
        errors.append("Gate 15 and Gate 16 must remain manual, with no Simulator pass job")

    manual_gate15 = require(
        "docs/gates/gate-15-real-device-acceptance.md",
        ("Status: NOT RUN", "signed iPhone", "paired Apple Watch", "Simulator run", "cannot mark Gate 15 as passed"),
        errors,
    )
    final_gate16 = require(
        "docs/gates/gate-16-final-release-acceptance.md",
        ("Status: NOT RUN", "Gates 1–14", "manual Gate 15 device evidence", "No Simulator result", "human release decision"),
        errors,
    )
    if not manual_gate15 or not final_gate16:
        errors.append("manual device and final release acceptance boundaries must be documented")

    scope = gate_contract(args.gate, errors)
    blocked = any("Gate 12 is blocked:" in error for error in errors)
    report = {
        "gate": args.gate,
        "scope": scope,
        "status": "blocked" if blocked else ("pass" if not errors else "error"),
        "blockers": [error for error in errors if "Gate 12 is blocked:" in error],
        "gate15IsManualDeviceAcceptance": True,
        "gate16RequiresHumanReleaseDecision": True,
        "simulatorCanMarkGate15Or16Passed": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Gate {args.gate} focused static contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
