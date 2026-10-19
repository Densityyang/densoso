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
                "HealthIntelligenceServiceTests.testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash",
                "HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches",
                "HealthProjectionActorTests",
                "DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState",
                "DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
                "HealthNarrativePolicyTests",
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
            "Packages/DensosoDomain/Sources/DensosoDomain/Health/HealthNarrative.swift",
            ("struct HealthNarrative:", "struct HealthNarrativeContext:", "let allowedEvidenceKeys:"),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/HealthNarrativeTests.swift",
            (
                "testNarrativeCodableContainsOnlyNarrativeFieldsAndEvidenceKeys",
                "testAllowedEvidenceKeysExcludeRecommendationIDsAndUnknownReferences",
            ),
            errors,
        )
        require(
            "Densoso/Application/Health/HealthNarrativePolicy.swift",
            ("func responseFormat", "func decode", "isNarrativeTextSafe", "deterministicFallback"),
            errors,
        )
        require(
            "Densoso/Application/Health/HealthContextPromptBuilder.swift",
            ("requiresNarrative(for userText: String)", "健康解读结构（强制）", "记录", "训练计划"),
            errors,
        )
        require(
            "Densoso/Agent/AgentSession.swift",
            (
                "healthNarrativeContextProvider",
                "provider.descriptor.id == .deepSeek",
                "provider.descriptor.capabilities.contains(.structuredOutput)",
                "HealthNarrativePolicy.decode",
                "exposeTextDeltas: !useStructuredHealthNarrative",
                "HealthNarrativePolicy.deterministicFallback",
            ),
            errors,
        )
        require(
            "Densoso/Services/HealthIntelligenceService.swift",
            ("func healthNarrativeContext(asOf date: Date = Date()) async throws", "never refreshes or writes caches"),
            errors,
        )
        require(
            "Densoso/Services/HealthProjectionActor.swift",
            (
                "@ModelActor",
                "func refresh(asOf date: Date = Date()) throws -> HealthIntelligenceRefreshSnapshot",
                "cachedDailyBrief(",
                "cachedWeeklyBrief(",
                "func todayHealthState(asOf date: Date = Date())",
                "func healthHistory(from startDate: Date, through endDate: Date)",
                "func healthNarrativeContext(asOf date: Date = Date())",
                "HealthIntelligenceReadModel(calendar: calendar)",
            ),
            errors,
        )
        require(
            "Densoso/Services/HealthIntelligenceService.swift",
            (
                "func refresh(asOf date: Date = Date()) async throws -> DailyHealthBrief?",
                "try await projectionActor.refresh(asOf: date)",
                "if snapshot.updatesWeeklyBrief",
            ),
            errors,
        )
        require(
            "Densoso/Services/HealthIntelligenceReadModel.swift",
            (
                "struct HealthIntelligenceReadModel",
                "func todayHealthState(asOf date: Date, in context: ModelContext)",
                "func healthHistory(",
                "HealthIntelligenceEngine(calendar: calendar)",
            ),
            errors,
        )
        require(
            "Densoso/App/Dependencies.swift",
            (
                "let healthProjectionActor: HealthProjectionActor",
                "HealthIntelligenceService(projectionActor: healthProjectionActor)",
                "try await healthProjectionActor.todayHealthState(asOf: date)",
                "try await healthProjectionActor.healthHistory(from: start, through: end)",
                "try? await healthProjectionActor.healthNarrativeContext()",
            ),
            errors,
        )
        require(
            "Densoso/Agent/AgentSession.swift",
            (
                "(@Sendable () async -> HealthNarrativeContext?)?",
                "let narrativeContext = await healthNarrativeContextProvider?()",
            ),
            errors,
        )
        require(
            "Densoso/Agent/Tools/GetTodayHealthStateTool.swift",
            ("@Sendable (Date) async throws -> HealthStateV2?", "let state = try await stateProvider(date)"),
            errors,
        )
        require(
            "Densoso/Agent/Tools/GetHealthHistoryTool.swift",
            ("@Sendable (Date, Date) async throws -> [HealthStateHistoryPoint]", "let points = try await historyProvider(startDay, endDay)"),
            errors,
        )
        require(
            "DensosoTests/Application/HealthProjectionActorTests.swift",
            (
                "testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites",
                "testActorHistoryRetainsExistingRangeValidation",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/HealthNarrativePolicyTests.swift",
            (
                "testStructuredNarrativeAcceptsOnlyKnownEvidenceKeysAndNarrativeText",
                "testNarrativeRejectsNumericMetricClaimsUnknownKeysAndExtraFields",
                "testPromptUsesStructuredContractOnlyForPersonalHealthQuestions",
                "testStateWithoutAggregateSummaryDoesNotProduceHealthConclusion",
            ),
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
                "Open-photo requests pass a bounded `MultimodalModelRequest` to that same",
                "matched barcode or usable local",
                "photo is not included in a model request",
                "must separately consent to DeepSeek meal-image upload",
                "OCR/evidence text is not persisted",
                "ephemeral provider message for the current round",
                "require the regular health-text consent",
                "Confirmation remains required",
                "evidence-only input must be rescanned under",
                "supplemental text in the same user turn",
                "same AgentSession",
                "textAndImage",
                "The envelope stores no image bytes",
                "a text-only or Qwen provider is rejected without fallback",
            ),
            errors,
        )
        chat = require(
            "Densoso/Views/ChatScreen.swift",
            (
                "inputText = speech.transcribedText",
                "dependencies.agentSession.send(userText:",
                "MealCaptureSheet(",
                "request.includingSupplementalText(",
                "inputText,",
                "multimodalRequest: requestWithSupplement",
                "inputEnvelope = VoiceCommandEnvelope(",
                "asInputEnvelope()",
                "onLocalPendingAction:",
                "path != .cloudDeepSeek",
            ),
            errors,
        )
        photo = require(
            "Densoso/Views/MealCaptureSheet.swift",
            (
                "let onSendToAgent: (MultimodalModelRequest) -> Void",
                "let onLocalPendingAction: (PendingAction) -> Void",
                "prepareCapture(data)",
                "prepareForAgent(originalData: originalData)",
                "onSendToAgent(preparedRequest)",
                "case .localReview(let review)",
                "case .textOnlyFallback(let prompt)",
                "stageLocalReview(localReview)",
                "onLocalPendingAction(action)",
                "条码和完整营养标签可在本机生成待确认草稿",
            ),
            errors,
        )
        require(
            "Densoso/Application/Meal/MealCaptureApplicationService.swift",
            (
                "func prepareForAgent(",
                "photoSanitizer.sanitize",
                "scanner.scan(imageJPEG: sanitized)",
                "return .localReview(review)",
                "return .textOnlyFallback(",
                "return .agentRequest(try MultimodalModelRequest(",
            ),
            errors,
        )
        session = require(
            "Densoso/Agent/AgentSession.swift",
            (
                "func send(multimodalRequest: MultimodalModelRequest",
                "provider.descriptor.capabilities.contains(.vision)",
                "dataClass: .mealImage",
                "requestSnapshot.containsTransientImage",
                "requestSnapshot.resumeCount > 0",
                "AgentError.transientImageRequired",
                "case .reasoning, .image: return false",
                "withoutTransientImages",
                "func currentMealImageEvidence()",
                "transientMealImageEvidence = multimodalRequest.mealEvidence",
                "providerMessagesIncludingTransientMealEvidence()",
                "transientMealEvidenceMessage",
                "messagesWithoutLocalMetadata",
                "inputEnvelope: message.inputEnvelope",
                "multimodalRequest.inputEnvelope.isWellFormed",
                "case invalidInputEnvelope",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Sources/DensosoDomain/InputEnvelope.swift",
            (
                "public struct InputEnvelope:",
                "case voiceAndImage",
                "imageAttachments: [ImageAttachment]",
                "public let locale: String",
                "asInputEnvelope(",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/InputEnvelopeTests.swift",
            (
                "testVoiceTextImageAndCombinedEnvelopeRoundTripOnlySafeMetadata",
                "testEnvelopeRejectsSourceAndPayloadMismatches",
                "testVoiceCommandOriginMapsToCoarseEnvelopeSourceWithoutLosingLocale",
                "source: .textAndImage",
            ),
            errors,
        )
        require(
            "Densoso/Infrastructure/LLM/LLMTypes.swift",
            (
                "let inputEnvelope: InputEnvelope",
                "source: .image",
                "private init(\n        userText: String,\n        image: ImageInput?",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/MultimodalAgentImageTests.swift",
            (
                "storedUserEnvelope.source, .voiceAndImage",
                "request.messages.allSatisfy { $0.inputEnvelope == nil }",
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
                "init(userText: String, mealEvidence: [MealEvidence])",
                "Self.boundedMealEvidence(mealEvidence)",
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
                "testVoiceInputEnvelopePersistsOnlySafeMetadataAndIsOmittedFromProviderMessages",
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
            ("testPinnedQwen37SnapshotUsesImageAndStructuredObservationContract",),
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
                "testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction",
                "testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion",
                "testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto",
                "testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount",
                "testLowConfidenceVisionCannotStageFoodIDWithoutUserSelection",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/MultimodalAgentImageTests.swift",
            (
                "testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence",
                "includingSupplementalText(supplementalText)",
                "XCTAssertEqual(userMessages.count, 2)",
                "testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget",
                "testEvidenceOnlyRequestUsesEphemeralProviderMessageWithoutImageConsentOrPersistence",
                "testInterruptedEvidenceOnlyRequestRequiresNewRequestToReprovideEvidence",
                "testEvidenceOnlyRequestBoundsTransientEvidence",
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
                "--filter HealthNarrativeTests",
                "-only-testing:DensosoTests/HealthRepositoryTests/testInsertAndDeleteReprojectsTheSameDay",
                "-only-testing:DensosoTests/CaloricEnergySemanticsTests/testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics",
                "-only-testing:DensosoTests/HealthIntelligenceServiceTests/testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash",
                "-only-testing:DensosoTests/HealthProjectionActorTests",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
                "-only-testing:DensosoTests/HealthNarrativePolicyTests",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays",
            ),
        ),
        12: (
            "gate-12-multimodal-agent",
            (
                "--filter InputEnvelopeTests",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence",
                "-only-testing:DensosoTests/AgentCoordinatorTests/testVoiceInputEnvelopePersistsOnlySafeMetadataAndIsOmittedFromProviderMessages",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testEvidenceOnlyRequestUsesEphemeralProviderMessageWithoutImageConsentOrPersistence",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testInterruptedEvidenceOnlyRequestRequiresNewRequestToReprovideEvidence",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testEvidenceOnlyRequestBoundsTransientEvidence",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testImageRequiresVisionCapabilityAndSeparateMealImageConsent",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount",
                "-only-testing:DensosoTests/DeepSeekProviderContractTests/testImageStructuredOutputAndStatelessToolHistoryEncoding",
                "-only-testing:DensosoTests/QwenASRProviderContractTests/testOpenAICompatibleAudioRequestAndResponseContract",
                "-only-testing:DensosoTests/QwenMealVisionProviderContractTests/testPinnedQwen37SnapshotUsesImageAndStructuredObservationContract",
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
