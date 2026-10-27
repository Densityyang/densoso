#!/usr/bin/env python3
"""Validate Gate 19 source contracts and structured CI evidence.

Usage:
  python scripts/validate_gate19_privacy_window.py \
      --evidence artifacts/gate19-evidence.json \
      --sanitized-provider-request-artifact artifacts/gate19-sanitized-provider-request-evidence.json \
      --report artifacts/gate19-report.json

The optional evidence manifest is JSON with this shape (status values are exact):
  {
    "schemaVersion": 1,
    "gate": "gate-19-cloud-health-privacy-window",
    "headSha": "<40-hex commit>",
    "runId": "<CI run id>",
    "testResults": {"<required app XCTest method>": "PASS"},
    "swiftPackageTestResults": {
      "HealthIntelligenceTests/testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial": "PASS"
    },
    "behaviorChecks": {
      "provider_final_request_body": {
        "status": "PASS", "evidenceRef": "sanitized-artifact.json",
        "providers": ["deepSeek", "qwen"],
        "forbiddenClassesChecked": ["healthNutrition", "healthSleep",
          "healthActivity", "healthBody", "healthSubjective"],
        "forbiddenSentinelsAbsent": true
      }
    }
  }

Required behaviorChecks IDs and PASS fields:
  provider_final_request_body: providers, forbiddenClassesChecked,
    forbiddenSentinelsAbsent=true
  retry_attempt_authorization: all retry-bound provider tests must pass
  provider_tool_output: the same fields plus derivedMetricsChecked=true
  cached_and_continued_context: the same fields plus policyChangeApplied=true
  consent_expansion_confirmation: providers, expansionRequiresConfirmation=true,
    automaticExpansionDenied=true
  imported_backup_reconfirmation: either requiresReconfirmation=true, or the
    current backup contract where policyTransferredInBackup=false and
    restoredConsentDefaultsDenied=true
  health_window: analysisLookbackDays=42; initialBackfillDays must be >=42,
    unless it is <42 and boundaryKind is authorization|dataAvailability with
    a non-empty boundaryStart; sameAnalysisAndSyncWindow and
    authorizationBoundaryRespected must also be true
  coverage_unknown_semantics: unknownDistinctFromNoData=true,
    unknownCoverageNotZero=true
  rebaseline_idempotence: repeatedSyncStable=true, cursorResetBounded=true
  delete_recompute_idempotence: deletionRecomputeStable=true

Each PASS behavioral check also needs a non-empty evidenceRef. The evidence
manifest must bind to the checked-out HEAD. The provider-request check requires
the sanitized JSON attachment exported from the current XCTest result bundle;
its exact schema and provider/class coverage are read and checked. Other
evidenceRef targets are not opened. This validator does not independently
execute XCTest or inspect provider traffic. An adapter test may inspect a
locally serialized URLRequest body through a scripted transport; that does not
prove what a live remote service received.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
GATE_ID = "gate-19-cloud-health-privacy-window"
SANITIZED_PROVIDER_REQUEST_ARTIFACT = "gate19-sanitized-provider-request-evidence.json"
SANITIZED_PROVIDER_REQUEST_TEST_METHOD = "testDeniedHealthClassSentinelsAreAbsentFromSerializedProviderContinuationBodies"
SANITIZED_PROVIDER_REQUEST_TEST = f"AgentProviderContextPolicyTests/{SANITIZED_PROVIDER_REQUEST_TEST_METHOD}"
STATUSES = {"PASS", "FAIL", "BLOCKED", "NOT_MEASURED"}
PROVIDERS = {"deepSeek", "qwen"}
HEALTH_CLASSES = {
    "healthNutrition",
    "healthSleep",
    "healthActivity",
    "healthBody",
    "healthSubjective",
}

REQUIRED_TESTS = (
    "testGranularConsentPersistsPerProviderAndDefaultsToDenied",
    "testUnconfiguredPolicyOmitsAutomaticHistoricalContext",
    "testSummaryKeepsOnlyAuthorizedCategoriesAndDropsCrossDomainDerivations",
    "testProviderContinuationRemovesForbiddenSleepAndSleepDerivedRecovery",
    "testProviderContinuationOmitsTrainingLoadWhenActivityIsNotAuthorized",
    "testHealthHistoryRecomputesStatusFromAuthorizedFieldsAndDropsForbiddenOnlyDates",
    "testAuthorizedUnknownHealthHistoryCoverageDoesNotBecomeNoDataOrZero",
    "testRestrictedEarlierHealthTurnIsRemovedFromProviderHistory",
    "testFinalHealthHistoryContinuationFailsClosedForEveryDeniedClassSentinel",
    "testGoalContinuationOmitsDailyDeficitWhenActivityIsNotAuthorized",
    "testPolicySnapshotPersistsMonotonicRevisionHashAndRequiresConfirmedExpansion",
    "testFinalProviderSendRejectsRevokedAndReconfirmedPolicyRevision",
    "testImageConsentReconfirmationAdvancesTheFinalSendPolicyRevision",
    "testConversationAlignmentRequiresExplicitOptInAndSeparatesRevocation",
    "testConversationHistoryIsProviderScopedIndependentAndRevisionBound",
    "testSummaryPreservesOnlyAuthorizedPerMetricWindowCoverage",
    "testCurrentTurnAssistantTextIsRemovedBeforeRestrictedContinuation",
    "testPastHealthNarrativeWithRevokedPolicyProvenanceIsRemovedForGenericUserWording",
    "testPastUnprovenancedAssistantNarrativeFailsClosedForGenericWording",
    "testPolicyRevisionChangeDoesNotRestorePreviouslyRevokedNarrativeAfterReconfirmation",
    "testAgentHealthPolicyAlignmentStagesDraftAndRequiresConversationConfirmation",
    "testConversationHistoryConsentDefaultsToCurrentTurnOnlyInProviderPayload",
    "testConfirmedConversationHistoryConsentIncludesCurrentRevisionHistoryInProviderPayload",
    "testDeniedHealthClassSentinelsAreAbsentFromSerializedProviderContinuationBodies",
    "testPreSerializationConsentCheckStopsBeforeDeepSeekRequestIsSent",
    "testPreSerializationConsentCheckStopsBeforeQwenRequestIsSent",
    "testSerializationConsentGateStopsBeforeNetworkRequest",
    "testDeepSeekStreamRetryRevalidatesCapturedPolicyRevision",
    "testQwenTextRetryRevalidatesCapturedPolicyRevision",
    "testQwenVisionRetryRevalidatesCapturedImagePolicyRevision",
    "testQwenASRRetryRejectsRevokedAndReconfirmedSpeechAudioConsent",
    "testPolicyRevocationDuringHealthToolExecutionFiltersTheContinuationRequest",
    "testReadModelReportsPerMetricCoverageAcrossTheFortyTwoDayHealthWindow",
    "testBackupDoesNotTransferCloudHealthConsentAndRestoreDefaultsToDenied",
    "testInitialHealthKitBackfillUsesTheSame42DayWindowForEveryStreamType",
    "testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays",
    "testUnavailableAuthorizationBoundaryRebuildsWindowAndKeepsEmptyDaysUnknown",
    "testHealthContextExportGateStartsClosedAndOpensAfterSuccessfulPurge",
    "testHealthContextExportGateCanAllowManualOnlyContextWithoutHealthKitCache",
    "testHealthContextExportGateStaysClosedWhenForegroundPurgeFails",
    "testHealthContextExportGateRejectsAnExportCrossingARebaseline",
    "testForegroundPurgeSupersedesAnInFlightDailyRebaselineBeforeItCanWrite",
    "testDailyRebaselineSupersedesAnInFlightForegroundRebaseline",
    "testForegroundPurgeSupersedesAnInFlightObserverAndSkipsItsRefreshCallback",
    "testHealthBriefCacheGenerationFenceRejectsPrePurgeWrites",
    "testInvalidatedBriefCacheDoesNotReloadPrePurgeBriefs",
    "testUnavailableBoundaryRebuildsOnlyAffectedStreamsAndAggregateFailureStaysUnknown",
    "testObserverWithUnavailableBoundaryKeepsStoredAnchorForIncrementalSync",
    "testSnapshotRebuildPurgesOnlyWindowHealthKitCacheAndPreservesManualWeights",
    "testAuthorizationBoundaryMaskClearsDerivedBriefCaches",
    "testReadModelHidesAggregateHealthValuesWhenTheirReadStatesAreUnknown",
    "testProjectionInputReaderFiltersHealthKitWorkoutsByDailyReadState",
    "testRepositoryOmitsHealthKitWorkoutsWithUnknownOrMissingReadState",
    "testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue",
    "testAuthorizationBoundaryAdvanceRebaselinesAndExcludesPreviouslyIndexedSamples",
    "testSubsequentSampleSyncUsesStoredAnchorInsteadOfReplayingThe42DayWindow",
    "testStoredSampleAnchorAppliesLateSamplesBeforeCurrentWindowStart",
    "testDeletedSampleBeforeCurrentWindowStartRequeriesHistoricalDay",
    "testShortExistingSampleWindowRebaselinesIdempotentlyTo42Days",
    "testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",
    "testHealthDataWindowPolicyUses42InclusiveDaysAndRespectsAuthorizationBoundary",
    "testHistoryResponsePreservesUnknownAndPartialCoverageWithoutAbsenceOrZero",
    "testReadModelHistoryKeepsUnknownHealthKitCoverageTypedWithoutZeroObservations",
    "testUnknownTrainingLoadOmitsZeroAndDerivedValuesAndReportsCoverage",
)

REQUIRED_DOMAIN_TESTS = (
    "HealthIntelligenceTests/testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial",
    "HealthIntelligenceTests/testLegacyTrainingLoadCacheWithoutCoverageDecodesUnknownAndOmitsNumericPlaceholders",
    "HealthIntelligenceTests/testLegacyHealthDomainVitalAndContextCachesFailClosedWithoutCoverage",
    "HealthIntelligenceTests/testMetricWindowCoverageReportsThirtyAuthorizedDaysWithinFortyTwoDayTarget",
    "HealthIntelligenceTests/testSleepWindowCoverageUsesFirstFullyAuthorizedWakeDay",
    "HealthStateTests/testUnknownAndPartialDomainStatusesDoNotBecomeUsableRecoveryEvidence",
    "HealthNarrativeTests/testNarrativeContextOmitsUnknownTrainingLoadZeroPlaceholders",
)
SWIFT_PACKAGE_TEST_FILTERS = REQUIRED_DOMAIN_TESTS
XCODE_REQUIRED_TESTS = REQUIRED_TESTS


@dataclass(frozen=True)
class BehaviorCheck:
    required_true: tuple[str, ...] = ()
    required_numbers: tuple[tuple[str, str, int], ...] = ()
    require_providers: bool = False
    require_health_classes: bool = False
    required_tests: tuple[str, ...] = ()


BEHAVIOR_CHECKS: dict[str, BehaviorCheck] = {
    "provider_final_request_body": BehaviorCheck(
        required_true=("forbiddenSentinelsAbsent", "conversationHistoryDefaultDenied"),
        require_providers=True,
        require_health_classes=True,
        required_tests=(
            "testDeniedHealthClassSentinelsAreAbsentFromSerializedProviderContinuationBodies",
            "testPreSerializationConsentCheckStopsBeforeDeepSeekRequestIsSent",
            "testPreSerializationConsentCheckStopsBeforeQwenRequestIsSent",
            "testSerializationConsentGateStopsBeforeNetworkRequest",
            "testFinalProviderSendRejectsRevokedAndReconfirmedPolicyRevision",
            "testImageConsentReconfirmationAdvancesTheFinalSendPolicyRevision",
            "testConversationHistoryConsentDefaultsToCurrentTurnOnlyInProviderPayload",
        ),
    ),
    "retry_attempt_authorization": BehaviorCheck(
        required_tests=(
            "testDeepSeekStreamRetryRevalidatesCapturedPolicyRevision",
            "testQwenTextRetryRevalidatesCapturedPolicyRevision",
            "testQwenVisionRetryRevalidatesCapturedImagePolicyRevision",
            "testQwenASRRetryRejectsRevokedAndReconfirmedSpeechAudioConsent",
        ),
    ),
    "provider_tool_output": BehaviorCheck(
        required_true=("forbiddenSentinelsAbsent", "derivedMetricsChecked"),
        require_providers=True,
        require_health_classes=True,
        required_tests=(
            "testFinalHealthHistoryContinuationFailsClosedForEveryDeniedClassSentinel",
            "testProviderContinuationRemovesForbiddenSleepAndSleepDerivedRecovery",
            "testGoalContinuationOmitsDailyDeficitWhenActivityIsNotAuthorized",
        ),
    ),
    "cached_and_continued_context": BehaviorCheck(
        required_true=("forbiddenSentinelsAbsent", "policyChangeApplied"),
        require_providers=True,
        require_health_classes=True,
        required_tests=(
            "testPolicySnapshotPersistsMonotonicRevisionHashAndRequiresConfirmedExpansion",
            "testFinalProviderSendRejectsRevokedAndReconfirmedPolicyRevision",
            "testImageConsentReconfirmationAdvancesTheFinalSendPolicyRevision",
            "testPolicyRevocationDuringHealthToolExecutionFiltersTheContinuationRequest",
            "testAgentHealthPolicyAlignmentStagesDraftAndRequiresConversationConfirmation",
            "testConversationAlignmentRequiresExplicitOptInAndSeparatesRevocation",
            "testConversationHistoryIsProviderScopedIndependentAndRevisionBound",
            "testConfirmedConversationHistoryConsentIncludesCurrentRevisionHistoryInProviderPayload",
            "testPastHealthNarrativeWithRevokedPolicyProvenanceIsRemovedForGenericUserWording",
            "testPastUnprovenancedAssistantNarrativeFailsClosedForGenericWording",
            "testPolicyRevisionChangeDoesNotRestorePreviouslyRevokedNarrativeAfterReconfirmation",
        ),
    ),
    "consent_expansion_confirmation": BehaviorCheck(
        required_true=("expansionRequiresConfirmation", "automaticExpansionDenied"),
        require_providers=True,
        required_tests=(
            "testPolicySnapshotPersistsMonotonicRevisionHashAndRequiresConfirmedExpansion",
            "testConversationHistoryIsProviderScopedIndependentAndRevisionBound",
            "testConversationAlignmentRequiresExplicitOptInAndSeparatesRevocation",
            "testAgentHealthPolicyAlignmentStagesDraftAndRequiresConversationConfirmation",
            "testConfirmedConversationHistoryConsentIncludesCurrentRevisionHistoryInProviderPayload",
        ),
    ),
    "imported_backup_reconfirmation": BehaviorCheck(
        required_tests=("testBackupDoesNotTransferCloudHealthConsentAndRestoreDefaultsToDenied",),
    ),
    "health_window": BehaviorCheck(
        required_true=("sameAnalysisAndSyncWindow", "authorizationBoundaryRespected"),
        required_numbers=(
            ("analysisLookbackDays", "exact", 42),
        ),
        required_tests=(
            "testInitialHealthKitBackfillUsesTheSame42DayWindowForEveryStreamType",
            "testReadModelReportsPerMetricCoverageAcrossTheFortyTwoDayHealthWindow",
            "HealthIntelligenceTests/testMetricWindowCoverageReportsThirtyAuthorizedDaysWithinFortyTwoDayTarget",
            "HealthIntelligenceTests/testSleepWindowCoverageUsesFirstFullyAuthorizedWakeDay",
            "testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays",
            "testUnavailableAuthorizationBoundaryRebuildsWindowAndKeepsEmptyDaysUnknown",
            "testHealthContextExportGateStartsClosedAndOpensAfterSuccessfulPurge",
            "testHealthContextExportGateCanAllowManualOnlyContextWithoutHealthKitCache",
            "testHealthContextExportGateStaysClosedWhenForegroundPurgeFails",
            "testHealthContextExportGateRejectsAnExportCrossingARebaseline",
            "testForegroundPurgeSupersedesAnInFlightDailyRebaselineBeforeItCanWrite",
            "testDailyRebaselineSupersedesAnInFlightForegroundRebaseline",
            "testForegroundPurgeSupersedesAnInFlightObserverAndSkipsItsRefreshCallback",
            "testHealthBriefCacheGenerationFenceRejectsPrePurgeWrites",
            "testInvalidatedBriefCacheDoesNotReloadPrePurgeBriefs",
            "testUnavailableBoundaryRebuildsOnlyAffectedStreamsAndAggregateFailureStaysUnknown",
            "testObserverWithUnavailableBoundaryKeepsStoredAnchorForIncrementalSync",
            "testSnapshotRebuildPurgesOnlyWindowHealthKitCacheAndPreservesManualWeights",
            "testAuthorizationBoundaryMaskClearsDerivedBriefCaches",
            "testReadModelHidesAggregateHealthValuesWhenTheirReadStatesAreUnknown",
            "testProjectionInputReaderFiltersHealthKitWorkoutsByDailyReadState",
            "testRepositoryOmitsHealthKitWorkoutsWithUnknownOrMissingReadState",
            "testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue",
            "testHealthDataWindowPolicyUses42InclusiveDaysAndRespectsAuthorizationBoundary",
            "testStoredSampleAnchorAppliesLateSamplesBeforeCurrentWindowStart",
        ),
    ),
    "coverage_unknown_semantics": BehaviorCheck(
        required_true=(
            "unknownDistinctFromNoData",
            "unknownCoverageNotZero",
            "unknownDomainStatusSerialized",
            "partialStatusPreserved",
            "legacyCacheFailsClosed",
            "trainingLoadNumbersOmittedWhenCoverageUnknown",
            "narrativeUnknownCoverageTyped",
        ),
        required_tests=(
            "testHistoryResponsePreservesUnknownAndPartialCoverageWithoutAbsenceOrZero",
            "testReadModelHistoryKeepsUnknownHealthKitCoverageTypedWithoutZeroObservations",
            "testAuthorizedUnknownHealthHistoryCoverageDoesNotBecomeNoDataOrZero",
            "testReadModelHidesAggregateHealthValuesWhenTheirReadStatesAreUnknown",
            "testProjectionInputReaderFiltersHealthKitWorkoutsByDailyReadState",
            "testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue",
            "testUnavailableAuthorizationBoundaryRebuildsWindowAndKeepsEmptyDaysUnknown",
            "testHealthContextExportGateStartsClosedAndOpensAfterSuccessfulPurge",
            "testHealthContextExportGateCanAllowManualOnlyContextWithoutHealthKitCache",
            "testHealthContextExportGateStaysClosedWhenForegroundPurgeFails",
            "testHealthContextExportGateRejectsAnExportCrossingARebaseline",
            "testForegroundPurgeSupersedesAnInFlightDailyRebaselineBeforeItCanWrite",
            "testDailyRebaselineSupersedesAnInFlightForegroundRebaseline",
            "testForegroundPurgeSupersedesAnInFlightObserverAndSkipsItsRefreshCallback",
            "testHealthBriefCacheGenerationFenceRejectsPrePurgeWrites",
            "testInvalidatedBriefCacheDoesNotReloadPrePurgeBriefs",
            "testUnavailableBoundaryRebuildsOnlyAffectedStreamsAndAggregateFailureStaysUnknown",
            "testUnknownTrainingLoadOmitsZeroAndDerivedValuesAndReportsCoverage",
            "HealthIntelligenceTests/testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial",
            "HealthIntelligenceTests/testLegacyTrainingLoadCacheWithoutCoverageDecodesUnknownAndOmitsNumericPlaceholders",
            "HealthIntelligenceTests/testLegacyHealthDomainVitalAndContextCachesFailClosedWithoutCoverage",
            "HealthStateTests/testUnknownAndPartialDomainStatusesDoNotBecomeUsableRecoveryEvidence",
            "HealthNarrativeTests/testNarrativeContextOmitsUnknownTrainingLoadZeroPlaceholders",
        ),
    ),
    "rebaseline_idempotence": BehaviorCheck(
        required_true=("repeatedSyncStable", "cursorResetBounded"),
        required_tests=(
            "testAuthorizationBoundaryAdvanceRebaselinesAndExcludesPreviouslyIndexedSamples",
            "testSnapshotRebuildPurgesOnlyWindowHealthKitCacheAndPreservesManualWeights",
            "testAuthorizationBoundaryMaskClearsDerivedBriefCaches",
            "testHealthContextExportGateStartsClosedAndOpensAfterSuccessfulPurge",
            "testHealthContextExportGateCanAllowManualOnlyContextWithoutHealthKitCache",
            "testHealthContextExportGateStaysClosedWhenForegroundPurgeFails",
            "testHealthContextExportGateRejectsAnExportCrossingARebaseline",
            "testForegroundPurgeSupersedesAnInFlightDailyRebaselineBeforeItCanWrite",
            "testDailyRebaselineSupersedesAnInFlightForegroundRebaseline",
            "testForegroundPurgeSupersedesAnInFlightObserverAndSkipsItsRefreshCallback",
            "testHealthBriefCacheGenerationFenceRejectsPrePurgeWrites",
            "testInvalidatedBriefCacheDoesNotReloadPrePurgeBriefs",
            "testSubsequentSampleSyncUsesStoredAnchorInsteadOfReplayingThe42DayWindow",
            "testShortExistingSampleWindowRebaselinesIdempotentlyTo42Days",
        ),
    ),
    "delete_recompute_idempotence": BehaviorCheck(
        required_true=("deletionRecomputeStable",),
        required_tests=(
            "testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",
            "testDeletedSampleBeforeCurrentWindowStartRequeriesHistoricalDay",
        ),
    ),
}


SOURCE_CONTRACTS: tuple[tuple[str, str, tuple[str, ...], tuple[str, ...]], ...] = (
    (
        "granular_provider_consent_defaults_denied",
        "Densoso/Infrastructure/LLM/LLMTypes.swift",
        (
            "case healthNutrition",
            "case healthSleep",
            "case healthActivity",
            "case healthBody",
            "case healthSubjective",
            "case conversationHistory",
            "var isHealthContextClass: Bool",
            "var isConversationHistoryClass: Bool",
        ),
        (),
    ),
    (
        "policy_loads_only_granted_classes",
        "Densoso/Application/Agent/CloudHealthContextPolicy.swift",
        (
            "static let dataClasses:",
            "static func load(from repository:",
            "if try await repository.isConsentGranted(provider: provider, dataClass: dataClass)",
            "allowed.insert(dataClass)",
            "func allowsDerivedRecovery",
        ),
        (),
    ),
    (
        "health_policy_snapshot_requires_confirmed_expansion",
        "Densoso/Application/Agent/CloudHealthContextPolicy.swift",
        (
            "struct CloudHealthContextPolicySnapshot: Codable",
            "let revision: Int",
            "let policyHash: String",
            "static func confirmExpandedPolicy(",
            "static func updateConversationHistoryConsent(",
            "guard additions.isEmpty || confirmedExpansion else",
            "confirmedAt: additions.isEmpty ? current.snapshot.confirmedAt : confirmedAt",
        ),
        (),
    ),
    (
        "agent_attaches_atomic_pre_serialization_policy_gate",
        "Densoso/Agent/AgentSession.swift",
        (
            "preSerializationGate: { serialize in",
            "CloudHealthContextPolicy.withCurrentSendConsentSerialization(",
        ),
        (),
    ),
    (
        "agent_attaches_per_attempt_policy_gate",
        "Densoso/Agent/AgentSession.swift",
        (
            "networkAttemptGate: {",
            "CloudHealthContextPolicy.withCurrentSendConsent(",
            "expectedHealthPolicy: roundPolicy",
        ),
        (),
    ),
    (
        "provider_retry_executor_checks_before_each_attempt",
        "Densoso/Infrastructure/LLM/ProviderHTTPTransport.swift",
        (
            "beforeNetworkAttempt: (@Sendable () async throws -> Void)? = nil",
            "try await beforeNetworkAttempt?()",
        ),
        (),
    ),
    (
        "governance_actor_checks_consent_and_serializes_atomically",
        "Densoso/Infrastructure/Persistence/SwiftDataProviderGovernanceRepository.swift",
        (
            "func withCurrentSendAuthorization<Result: Sendable>(",
            "let currentSnapshot = try currentCloudHealthContextPolicySnapshot(provider: provider)",
            "currentSnapshot == expectedSnapshot",
            "for dataClass in requiredClasses.sorted(",
            "return try operation()",
        ),
        (),
    ),
    (
        "deepseek_serializes_inside_policy_gate",
        "Densoso/Infrastructure/LLM/DeepSeekProvider.swift",
        ("if let gate = request.preSerializationGate", "body = try await gate {"),
        (),
    ),
    (
        "deepseek_stream_rechecks_policy_before_each_attempt",
        "Densoso/Infrastructure/LLM/DeepSeekProvider.swift",
        ("beforeNetworkAttempt: request.networkAttemptGate",),
        (),
    ),
    (
        "qwen_serializes_inside_policy_gate",
        "Densoso/Infrastructure/LLM/QwenProvider.swift",
        ("if let gate = request.preSerializationGate", "body = try await gate {"),
        (),
    ),
    (
        "qwen_text_rechecks_policy_before_each_attempt",
        "Densoso/Infrastructure/LLM/QwenProvider.swift",
        ("beforeNetworkAttempt: request.networkAttemptGate",),
        (),
    ),
    (
        "qwen_meal_vision_uses_policy_serialization_gate",
        "Densoso/Infrastructure/LLM/QwenMealVisionProvider.swift",
        ("serializationGate: @escaping", "let body = try await serializationGate {"),
        (),
    ),
    (
        "optional_qwen_meal_image_path_injects_current_policy_gate",
        "Densoso/Application/Meal/MealCaptureApplicationService.swift",
        (
            "let expectedImagePolicy = try await CloudHealthContextPolicy.load(",
            "serializationGate: { serialize in",
            "requiresHealthText: false",
        ),
        (),
    ),
    (
        "qwen_meal_vision_rechecks_policy_before_retry",
        "Densoso/Infrastructure/LLM/QwenMealVisionProvider.swift",
        (
            "beforeNetworkAttempt: {",
            "_ = try await serializationGate { Data() }",
        ),
        (),
    ),
    (
        "qwen_asr_rechecks_speech_audio_consent_before_retry",
        "Densoso/Services/SpeechService.swift",
        (
            "beforeNetworkAttempt: {",
            "dataClass: .speechAudio",
            "cloudProvider.transcribe(",
            "expectedSpeechPolicy",
            "additionalRequiredClasses: [.speechAudio]",
        ),
        (),
    ),
    (
        "qwen_asr_provider_passes_attempt_gate_to_executor",
        "Densoso/Infrastructure/LLM/QwenASRProvider.swift",
        ("beforeNetworkAttempt: beforeNetworkAttempt",),
        (),
    ),
    (
        "all_provider_consent_changes_advance_policy_revision",
        "Densoso/Infrastructure/Persistence/SwiftDataProviderGovernanceRepository.swift",
        (
            "let previousPolicy = try? currentCloudHealthContextPolicySnapshot(provider: provider)",
            "revision: prior.revision + 1",
            "changesHealthPolicy && granted ? now : prior.confirmedAt",
        ),
        (),
    ),
    (
        "settings_and_onboarding_confirm_cloud_health_policy",
        "Densoso/Views/SettingsScreen.swift",
        (
            ".confirmationDialog(",
            "确认扩展云端健康数据授权？",
            "confirmHealthPolicyExpansion(",
            "CloudHealthContextPolicy.confirmExpandedPolicy(",
            "CloudHealthContextPolicy.applyRestrictiveChange(",
            "conversationHistoryConsentControl(",
            "saveConversationHistoryConsent(",
            "changeSource: .settings",
        ),
        (),
    ),
    (
        "onboarding_health_context_defaults_to_opt_in",
        "Densoso/Views/OnboardingView.swift",
        (
            "@State private var cloudHealthContextClasses: Set<ProviderDataClass> = []",
            "@State private var cloudConversationHistoryConsent = false",
            "允许发送此前与云端助手的聊天记录",
            "private var healthContextConsentControls: some View",
            "CloudHealthContextPolicy.confirmExpandedPolicy(",
            "changeSource: .onboarding",
        ),
        (),
    ),
    (
        "health_narrative_provenance_is_saved_and_history_fails_closed",
        "Densoso/Application/Agent/CloudHealthContextPolicy.swift",
        (
            "message.healthContextPolicyProvenance == nil",
            "provenance.policyRevision != policy.revision",
            "containsUnprovenancedConversationMessage",
            "!containsUnprovenancedConversationMessage",
            "policy.allowsConversationHistory",
            "return ModelMessage(role: .assistant, content: toolCalls)",
        ),
        (),
    ),
    (
        "consent_storage_key_is_provider_and_class_scoped",
        "Densoso/Infrastructure/Persistence/SwiftDataProviderGovernanceRepository.swift",
        (
            "func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass)",
            "func setConsent(",
            "dataClass.isConversationHistoryClass",
            "func updateConversationHistoryConsent(",
            "consentKey(provider: provider, dataClass: dataClass)",
            '"provider|\\(provider.rawValue)|\\(dataClass.rawValue)"',
        ),
        (),
    ),
    (
        "provider_request_and_continuation_guard",
        "Densoso/Agent/AgentSession.swift",
        (
            "CloudHealthContextPolicy.load(",
            "initialCloudHealthPolicy",
            "roundPolicy",
            "sendPolicy",
            "CloudRequestPolicyGuard.filtered(",
            "CloudRequestPolicyGuard.filterConversationHistory(",
            "CloudRequestPolicyGuard.filterToolResults(",
            "handleCloudHealthPolicyAlignment(",
            "activeCloudHealthPolicy = roundPolicy",
            "CloudHealthContextPolicy.stageConversationExpansion(",
            "CloudHealthContextPolicy.confirmPendingConversationExpansion(",
            "CloudHealthContextPolicy.cancelPendingConversationExpansion(",
        ),
        (),
    ),
    (
        "summary_and_derived_metric_filtering",
        "Densoso/Application/Agent/CloudHealthContextPolicy.swift",
        (
            "static func filtered(_ summary: HealthContextSummary, by policy:",
            "policy.allows(coverageKey: key)",
            "averageSleepMinutes: policy.allows(.healthSleep)",
            "averageEnergyIntakeKcal: policy.allows(.healthNutrition)",
            "policy.allows(.healthNutrition) && policy.allows(.healthActivity)",
            "policy.allowsDerivedRecovery",
        ),
        (),
    ),
    (
        "typed_metric_window_coverage_is_decoded_and_threaded",
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthIntelligence.swift",
        (
            "public struct HealthMetricWindowCoverage: Codable",
            "public let targetWindowStart: Date",
            "public let actualEarliestDate: Date?",
            "public let expectedCalendarDays: Int",
            "public let validCalendarDays: Int",
            "public let missingCalendarDays: Int",
            "public let authorizationLimited: Bool",
            "public let dataAvailabilityLimited: Bool",
            "public let metricWindowCoverage: [String: HealthMetricWindowCoverage]",
            "public let analysisWindowCoverage: [String: HealthMetricWindowCoverage]",
        ),
        (),
    ),
    (
        "goal_tool_result_filters_cross_domain_goal_fields",
        "Densoso/Application/Agent/CloudHealthContextPolicy.swift",
        (
            'case "get_goal":',
            "return filterGoalResult(result, by: policy)",
            "private static func filterGoalResult(",
            "canReadBodyGoals",
            "policy.allows(.healthActivity)",
            'safeGoal["dailyDeficitKcal"] = value',
        ),
        (),
    ),
    (
        "history_filters_fields_and_recomputes_status",
        "Densoso/Application/Agent/CloudHealthContextPolicy.swift",
        (
            "private static func filterHealthHistory(",
            "statuses = source.filter",
            "observations = source.filter",
            "let hasObservations = filteredDays.contains",
            "let hasUnknownOrPartialCoverage = filteredDays.contains",
            'status = "partial"',
            'status = "noData"',
            'status = "available"',
            "未授权类别不代表没有记录",
        ),
        ('safeRoot["message"] = root["message"]', 'safeRoot["status"] = root["status"]'),
    ),
    (
        "shared_health_window_policy",
        "Densoso/Application/Health/HealthDataWindowPolicy.swift",
        (
            "static let analysisLookbackDays = 42",
            "static let initialBackfillDays = 42",
            "static func analysisStart(",
            "static func initialBackfillStart(",
            "static func effectiveStart(",
            "return max(policyStart, authorizationStart)",
            "static func firstFullyAuthorizedDay(",
            "static func requiresRebaseline(",
        ),
        (),
    ),
    (
        "sync_and_analysis_share_window",
        "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
        (
            "HealthDataWindowPolicy.initialBackfillStart(",
            "HealthDataWindowPolicy.effectiveStart(",
            "HealthDataWindowPolicy.requiresRebaseline(",
            "maskCachedHealthDataIfNeeded(",
            "markHealthWindowUnknown(",
            "resetHealthKitCursors()",
        ),
        (),
    ),
    (
        "unavailable_healthkit_boundary_rebuilds_a_bounded_snapshot",
        "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
        (
            "authorizationBoundaryUnavailable",
            "authorizationBoundaryUnavailable = true",
            "snapshotRebuildMetrics",
            "prepareHealthKitSnapshotRebuild(",
            "plan.authorizationBoundaryUnavailable",
            "if forceRebaseline",
        ),
        ("throw HealthStoreClientError.authorizationBoundaryUnavailable",),
    ),
    (
        "foreground_and_daily_refresh_rebaseline_before_using_health_context",
        "Densoso/App/DensosoApp.swift",
        (
            ".onAppear",
            "prepareHealthRebaselineForCurrentForegroundActivation()",
            "prepareForegroundSnapshotRebuild(using: repository)",
            "rebaselineHealthForCurrentForegroundActivation()",
            "forceRebaseline: true",
            "preparedSnapshotRebuild: rebuild",
            "isRunningForegroundHealthRebaselineTask",
            "isForegroundHealthRebaselineQueued",
            "healthContextExportGate.closeForSnapshotRebuild()",
            ".onChange(of: scenePhase)",
            "hasRebaselinedHealthForForeground = false",
        ),
        (),
    ),
    (
        "foreground_rebaseline_hides_cache_before_async_sync_and_context_serialization",
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        (
            "staleContextJSON.contains(\"123.456789\")",
            "prepareForegroundSnapshotRebuild(using: repository, now: now)",
            "rebuiltContextJSON.contains(\"123.456789\")",
            "preparedSnapshotRebuild: preparation",
        ),
        (),
    ),
    (
        "cloud_health_exports_require_a_successful_snapshot_purge",
        "Densoso/App/Dependencies.swift",
        (
            "final class HealthContextExportGate",
            "private(set) var isOpen = false",
            "func closeForSnapshotRebuild() -> UInt64",
            "func openAfterSuccessfulPurge(generation expectedGeneration: UInt64)",
            "func withAllowedExport<Value: Sendable>(",
            "guard isOpen, generation == expectedGeneration else",
            "todayHealthStateProvider: { date in\n                try await healthContextExportGate.withAllowedExport",
            "healthHistoryProvider: { start, end in\n                try await healthContextExportGate.withAllowedExport",
            "goalProfileProvider: { date in\n                try await healthContextExportGate.withAllowedExport",
            "healthNarrativeContextProvider: {\n                try await healthContextExportGate.withAllowedExport",
        ),
        (),
    ),
    (
        "coordinator_closes_context_gate_before_purge_and_opens_after_success",
        "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
        (
            "var onHealthCachePurgeWillBegin:",
            "var onHealthCachePurgeDidSucceed:",
            "let gateGeneration = onHealthCachePurgeWillBegin?()",
            "onHealthCachePurgeDidSucceed?(gateGeneration)",
            "try repository.prepareHealthKitSnapshotRebuild(",
        ),
        (),
    ),
    (
        "health_sync_generation_fences_all_post_await_commits",
        "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
        (
            "private var scanGenerationByMetric: [HealthMetricID: UInt64] = [:]",
            "private func advanceScanGenerations(for metrics: Set<HealthMetricID>)",
            "private func ensureCurrentScanGeneration(_ expected: UInt64, for metric: HealthMetricID)",
            "let scanGeneration = advanceScanGenerations(for: [metric])[metric]",
            "try ensureCurrentScanGeneration(scanGeneration, for: metric)",
            "scanGenerations.merge(generations, uniquingKeysWith: { _, new in new })",
            "onObserverSyncCompleted?(metric, scanGeneration)",
        ),
        (),
    ),
    (
        "health_brief_cache_commits_are_generation_fenced",
        "Densoso/Services/HealthProjectionActor.swift",
        (
            "let briefCacheGenerationFence: HealthBriefCacheGenerationFence",
            "cacheGeneration: UInt64",
            "withCurrentGeneration(cacheGeneration)",
        ),
        (),
    ),
    (
        "health_brief_cache_is_invalidated_before_health_purge",
        "Densoso/App/Dependencies.swift",
        (
            "healthIntelligenceService.invalidateBriefsForHealthSnapshotRebuild()",
            "healthContextExportGate.closeForSnapshotRebuild()",
        ),
        (),
    ),
    (
        "manual_only_context_gate_open_requires_no_persisted_healthkit_cache",
        "Densoso/App/Dependencies.swift",
        (
            "initiallyOpen: !healthKitService.hasRequestedAuthorization && !hasCachedHealthKitData",
            "private static func hasPersistedHealthKitData(in context: ModelContext) -> Bool",
            "if !cursors.isEmpty { return true }",
            "if !sampleIndexes.isEmpty { return true }",
            "snapshot.healthReadStates?.isEmpty == false",
        ),
        (),
    ),
    (
        "restored_healthkit_cache_is_purged_without_authorization_query",
        "Densoso/App/DensosoApp.swift",
        (
            "A restored snapshot can contain HealthKit markers",
            "guard !dependencies.healthContextExportGate.isOpen else { return }",
            "prepareForegroundSnapshotRebuild(using: repository)",
        ),
        (),
    ),
    (
        "health_snapshot_rebuild_clears_persisted_brief_caches",
        "Densoso/Services/HealthRepository.swift",
        (
            "modelContext.fetch(FetchDescriptor<DailyBriefRecord>())",
            "modelContext.fetch(FetchDescriptor<WeeklyBriefRecord>())",
            "modelContext.delete(brief)",
        ),
        (),
    ),
    (
        "authorization_boundary_mask_clears_persisted_brief_caches",
        "Densoso/Services/HealthRepository.swift",
        (
            "func maskCachedHealthDataBeforeAuthorizationBoundary(",
            "try removeHealthIntelligenceBriefCaches()",
        ),
        (),
    ),
    (
        "daily_background_health_refresh_uses_a_full_window_rebaseline",
        "Densoso/Application/DailyLoop/DailyLoopBackgroundScheduler.swift",
        (
            "syncAvailableData(",
            "forceRebaseline: true",
        ),
        (),
    ),
    (
        "healthkit_snapshot_rebuild_clears_only_window_cache_and_indexes",
        "Densoso/Services/HealthRepository.swift",
        (
            "func prepareHealthKitSnapshotRebuild(",
            "HealthDataWindowPolicy.days(from: firstDay, through: lastDay",
            "removeHealthKitSampleIndexes(",
            "removeImportedWorkouts(\n                        from: firstDay",
            "removeImportedHealthKitWeights(\n                        from: firstDay",
            "dataUnavailableOrReadScopeUnknown",
            "latestLocalWeightKilograms(on: day)",
        ),
        (),
    ),
    (
        "authorization_boundary_masks_historical_cache_and_keeps_changed_days",
        "Densoso/Services/HealthRepository.swift",
        (
            "maskCachedHealthDataBeforeAuthorizationBoundary",
            "private func maskCachedHealthSnapshots(",
            "private func removeImportedWorkouts(",
            "private func removeImportedHealthKitWeights(",
            "changedHealthSampleDays(for page:",
            "pendingHealthSampleDays(stream:",
        ),
        (),
    ),
    (
        "read_model_uses_shared_analysis_window",
        "Densoso/Services/HealthIntelligenceReadModel.swift",
        (
            "HealthDataWindowPolicy.analysisStart(",
            "HealthDataWindowPolicy.subjectiveCheckInLookbackDays",
            "projectionReadStates[HealthMetricID.activeEnergy.rawValue] == .available",
            "projectionReadStates[HealthMetricID.stepCount.rawValue] == .available",
            "projectionReadStates[HealthMetricID.exerciseMinutes.rawValue] == .available",
        ),
        (),
    ),
    (
        "daily_health_snapshot_projection_values_require_available_state",
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthDomainDrafts.swift",
        (
            "guard healthReadStates?[HealthMetricID.activeEnergy.rawValue] == .available else { return nil }",
            "guard healthReadStates?[HealthMetricID.restingEnergy.rawValue] == .available else { return nil }",
            "guard healthReadStates?[HealthMetricID.stepCount.rawValue] == .available else { return nil }",
            "guard healthReadStates?[HealthMetricID.exerciseMinutes.rawValue] == .available else { return nil }",
        ),
        (),
    ),
    (
        "daily_metrics_and_confirmation_use_gated_health_projection_accessors",
        "Densoso/Services/DailyMetricsProjector.swift",
        (
            "healthSnapshot?.activeEnergyForProjection",
            "healthSnapshot?.restingEnergyForProjection",
            "healthSnapshot?.stepCountForProjection",
            "healthSnapshot?.exerciseMinutesForProjection",
        ),
        (),
    ),
    (
        "confirmation_projection_uses_gated_health_accessors",
        "Densoso/Infrastructure/Persistence/SwiftDataConfirmationRepository.swift",
        (
            "healthSnapshot?.activeEnergyForProjection",
            "healthSnapshot?.restingEnergyForProjection",
            "healthSnapshot?.stepCountForProjection",
            "healthSnapshot?.exerciseMinutesForProjection",
        ),
        (),
    ),
    (
        "projection_inputs_filter_unknown_healthkit_workouts",
        "Densoso/Services/DailyMetricsProjectionInputReader.swift",
        (
            "healthKitWorkoutReadState(on: day, calendar: calendar, in: modelContext)",
            "workout.healthKitUUID == nil || workoutReadState == .available",
        ),
        (),
    ),
    (
        "recent_workout_tool_filters_unknown_healthkit_workouts",
        "Densoso/Infrastructure/Persistence/SwiftDataAgentRepository.swift",
        (
            "healthKitWorkoutReadStates(for: page)",
            "readStates[Self.dayKey(for: workout.date)] == .available",
            "private func healthKitWorkoutReadStates(for workouts:",
        ),
        (),
    ),
    (
        "healthkit_unknown_read_scope_not_encoded_as_zero",
        "Densoso/Infrastructure/HealthKit/HealthKitHealthStoreClient.swift",
        (
            ".dataUnavailableOrReadScopeUnknown",
            ".available",
        ),
        (),
    ),
    (
        "stable_healthkit_authorization_boundary_is_explicit_without_global_proxy",
        "Densoso/Infrastructure/HealthKit/HealthKitHealthStoreClient.swift",
        (
            "func earliestAuthorizedSampleDate(for metric: HealthMetricID) async throws -> Date?",
            "throw HealthStoreClientError.authorizationBoundaryUnavailable",
        ),
        ("earliestPermittedSampleDate", "getEarliestAuthorizedSampleDate"),
    ),
    (
        "unknown_partial_domain_and_legacy_cache_fail_closed",
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthIntelligence.swift",
        (
            "case unknown",
            "case partial",
            "public enum HealthDataCoverage",
            "public let dataCoverage: HealthDataCoverage",
            "dataCoverage: HealthDataCoverage? = nil",
            "?? (domain == .nutrition ? .complete : .unknown)",
            "decodedCoverage == .unknown",
            "decodedCoverage == .complete",
            "guard dataCoverage == .complete else { return }",
            "private func healthReadCoverage(",
        ),
        (),
    ),
    (
        "read_model_preserves_unknown_healthkit_coverage",
        "Densoso/Services/HealthIntelligenceReadModel.swift",
        (
            "projectionReadStates[metric.rawValue] = .dataUnavailableOrReadScopeUnknown",
            "guard projectionReadStates[metric.rawValue] == .available else { return nil }",
            "bodyMassReadState == .available",
            "$0.source != \"healthKit\" || bodyMassReadState == .available",
            "$0.healthKitUUID == nil || workoutReadState == .available",
            "projectionReadStates[HealthMetricID.activeEnergy.rawValue] == .available",
            "healthReadStates: projectionReadStates",
        ),
        (),
    ),
    (
        "history_tool_serializes_unknown_partial_without_zero_load",
        "Densoso/Agent/Tools/GetHealthHistoryTool.swift",
        (
            "HealthDomainStatus.unknown.rawValue",
            "HealthDomainStatus.partial.rawValue",
            "point.state.trainingLoad.dataCoverage == .complete",
            "trainingLoadCoverage: loadCoverage.rawValue",
            "loadCoverage == .complete ? point.state.trainingLoad.band.rawValue : nil",
            "status = hasGaps ? .partial : .noData",
        ),
        (),
    ),
    (
        "today_tool_serializes_unknown_partial_without_zero_load",
        "Densoso/Agent/Tools/GetTodayHealthStateTool.swift",
        (
            "state.trainingLoad.dataCoverage == .complete",
            "let dataCoverage: HealthDataCoverage",
            "let isComplete = summary.dataCoverage == .complete",
            "estimatedWorkoutCount = isComplete ? summary.estimatedWorkoutCount : nil",
        ),
        (),
    ),
    (
        "health_intelligence_cache_version_invalidates_old_coverage",
        "Packages/DensosoDomain/Sources/DensosoDomain/AlgorithmVersions.swift",
        ("public static let healthIntelligence = \"health-intelligence-v3\"",),
        (),
    ),
    (
        "backup_does_not_transfer_cloud_policy",
        "Densoso/Services/ExportService.swift",
        (
            "struct BackupPayload: Codable",
            "private func makePayload(context: ModelContext) throws -> BackupPayload",
            "return BackupPayload(",
        ),
        ("ConsentRecord", "consentKey", "ProviderDataClass"),
    ),
)


TEST_FILE_CONTRACTS: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    (
        "provider_retry_reauthorization_tests_present",
        "DensosoTests/Infrastructure/LLM/ProviderRetryPolicyTests.swift",
        (
            "testDeepSeekStreamRetryRevalidatesCapturedPolicyRevision",
            "testQwenTextRetryRevalidatesCapturedPolicyRevision",
            "testQwenASRRetryRejectsRevokedAndReconfirmedSpeechAudioConsent",
        ),
    ),
    (
        "cloud_health_policy_tests_present",
        "DensosoTests/Application/CloudHealthContextPolicyTests.swift",
        (
            "testGranularConsentPersistsPerProviderAndDefaultsToDenied",
            "testPolicySnapshotPersistsMonotonicRevisionHashAndRequiresConfirmedExpansion",
            "testConversationHistoryIsProviderScopedIndependentAndRevisionBound",
            "testConversationAlignmentRequiresExplicitOptInAndSeparatesRevocation",
            "testUnconfiguredPolicyOmitsAutomaticHistoricalContext",
            "testSummaryKeepsOnlyAuthorizedCategoriesAndDropsCrossDomainDerivations",
            "testSummaryPreservesOnlyAuthorizedPerMetricWindowCoverage",
            "testCurrentTurnAssistantTextIsRemovedBeforeRestrictedContinuation",
            "testPastHealthNarrativeWithRevokedPolicyProvenanceIsRemovedForGenericUserWording",
            "testPastUnprovenancedAssistantNarrativeFailsClosedForGenericWording",
            "testPolicyRevisionChangeDoesNotRestorePreviouslyRevokedNarrativeAfterReconfirmation",
            "testProviderContinuationRemovesForbiddenSleepAndSleepDerivedRecovery",
            "testProviderContinuationOmitsTrainingLoadWhenActivityIsNotAuthorized",
            "testHealthHistoryRecomputesStatusFromAuthorizedFieldsAndDropsForbiddenOnlyDates",
            "testAuthorizedUnknownHealthHistoryCoverageDoesNotBecomeNoDataOrZero",
            "testRestrictedEarlierHealthTurnIsRemovedFromProviderHistory",
            "testFinalHealthHistoryContinuationFailsClosedForEveryDeniedClassSentinel",
            "testGoalContinuationOmitsDailyDeficitWhenActivityIsNotAuthorized",
        ),
    ),
    (
        "health_intelligence_service_metric_coverage_test_present",
        "DensosoTests/HealthIntelligenceServiceTests.swift",
        ("testReadModelReportsPerMetricCoverageAcrossTheFortyTwoDayHealthWindow",),
    ),
    (
        "health_brief_invalidation_tests_present",
        "DensosoTests/HealthIntelligenceServiceTests.swift",
        (
            "testHealthBriefCacheGenerationFenceRejectsPrePurgeWrites",
            "testInvalidatedBriefCacheDoesNotReloadPrePurgeBriefs",
        ),
    ),
    (
        "health_context_export_gate_manual_only_test_present",
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        ("testHealthContextExportGateCanAllowManualOnlyContextWithoutHealthKitCache",),
    ),
    (
        "health_window_sync_tests_present",
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        (
            "testInitialHealthKitBackfillUsesTheSame42DayWindowForEveryStreamType",
            "testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays",
            "testUnavailableAuthorizationBoundaryRebuildsWindowAndKeepsEmptyDaysUnknown",
            "testUnavailableBoundaryRebuildsOnlyAffectedStreamsAndAggregateFailureStaysUnknown",
            "testObserverWithUnavailableBoundaryKeepsStoredAnchorForIncrementalSync",
            "testSnapshotRebuildPurgesOnlyWindowHealthKitCacheAndPreservesManualWeights",
            "testAuthorizationBoundaryMaskClearsDerivedBriefCaches",
            "testForegroundPurgeSupersedesAnInFlightDailyRebaselineBeforeItCanWrite",
            "testDailyRebaselineSupersedesAnInFlightForegroundRebaseline",
            "testForegroundPurgeSupersedesAnInFlightObserverAndSkipsItsRefreshCallback",
            "testReadModelHidesAggregateHealthValuesWhenTheirReadStatesAreUnknown",
            "testAuthorizationBoundaryAdvanceRebaselinesAndExcludesPreviouslyIndexedSamples",
            "olderSampleDay",
            "HealthKitWeightObservationReader.latestObservation(in: context, effectiveAt: now)",
            "testSubsequentSampleSyncUsesStoredAnchorInsteadOfReplayingThe42DayWindow",
            "testStoredSampleAnchorAppliesLateSamplesBeforeCurrentWindowStart",
            "testDeletedSampleBeforeCurrentWindowStartRequeriesHistoricalDay",
            "testShortExistingSampleWindowRebaselinesIdempotentlyTo42Days",
            "testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",
            "testHealthDataWindowPolicyUses42InclusiveDaysAndRespectsAuthorizationBoundary",
        ),
    ),
    (
        "unknown_healthkit_projection_and_recent_workout_tests_present",
        "DensosoTests/DailyMetricsProjectionFingerprintTests.swift",
        ("testProjectionInputReaderFiltersHealthKitWorkoutsByDailyReadState",),
    ),
    (
        "recent_workout_repository_unknown_state_test_present",
        "DensosoTests/Application/GetRecentWorkoutsToolTests.swift",
        ("testRepositoryOmitsHealthKitWorkoutsWithUnknownOrMissingReadState",),
    ),
    (
        "unknown_aggregate_projection_test_present",
        "DensosoTests/HealthRepositoryTests.swift",
        ("testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue",),
    ),
    (
        "provider_adapter_continuation_body_test_present",
        "DensosoTests/Application/AgentProviderContextPolicyTests.swift",
        ("testDeniedHealthClassSentinelsAreAbsentFromSerializedProviderContinuationBodies",),
    ),
    (
        "revoked_policy_continuation_test_present",
        "DensosoTests/Application/AgentRequestResumeTests.swift",
        ("testPolicyRevocationDuringHealthToolExecutionFiltersTheContinuationRequest",),
    ),
    (
        "agent_health_policy_conversation_alignment_test_present",
        "DensosoTests/Application/AgentRequestResumeTests.swift",
        ("testAgentHealthPolicyAlignmentStagesDraftAndRequiresConversationConfirmation",),
    ),
    (
        "conversation_history_payload_default_deny_test_present",
        "DensosoTests/Application/AgentRequestResumeTests.swift",
        ("testConversationHistoryConsentDefaultsToCurrentTurnOnlyInProviderPayload",),
    ),
    (
        "provider_serialization_policy_preflight_tests_present",
        "DensosoTests/Infrastructure/LLM/DeepSeekProviderContractTests.swift",
        ("testPreSerializationConsentCheckStopsBeforeDeepSeekRequestIsSent",),
    ),
    (
        "qwen_serialization_policy_preflight_test_present",
        "DensosoTests/Infrastructure/LLM/QwenProviderContractTests.swift",
        ("testPreSerializationConsentCheckStopsBeforeQwenRequestIsSent",),
    ),
    (
        "qwen_meal_vision_serialization_gate_test_present",
        "DensosoTests/Infrastructure/LLM/QwenMealVisionProviderContractTests.swift",
        (
            "testSerializationConsentGateStopsBeforeNetworkRequest",
            "testQwenVisionRetryRevalidatesCapturedImagePolicyRevision",
        ),
    ),
    (
        "conversation_history_payload_explicit_consent_test_present",
        "DensosoTests/Application/AgentRequestResumeTests.swift",
        ("testConfirmedConversationHistoryConsentIncludesCurrentRevisionHistoryInProviderPayload",),
    ),
    (
        "backup_default_deny_test_present",
        "DensosoTests/ExportServiceTests.swift",
        ("testBackupDoesNotTransferCloudHealthConsentAndRestoreDefaultsToDenied",),
    ),
    (
        "history_unknown_coverage_tool_tests_present",
        "DensosoTests/Application/GetHealthHistoryToolTests.swift",
        (
            "testHistoryResponsePreservesUnknownAndPartialCoverageWithoutAbsenceOrZero",
            "testReadModelHistoryKeepsUnknownHealthKitCoverageTypedWithoutZeroObservations",
        ),
    ),
    (
        "today_unknown_coverage_tool_test_present",
        "DensosoTests/Application/GetTodayHealthStateToolTests.swift",
        ("testUnknownTrainingLoadOmitsZeroAndDerivedValuesAndReportsCoverage",),
    ),
    (
        "domain_unknown_coverage_tests_present",
        "Packages/DensosoDomain/Tests/DensosoDomainTests/HealthIntelligenceTests.swift",
        (
            "testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial",
            "testLegacyTrainingLoadCacheWithoutCoverageDecodesUnknownAndOmitsNumericPlaceholders",
            "testLegacyHealthDomainVitalAndContextCachesFailClosedWithoutCoverage",
        ),
    ),
    (
        "state_unknown_coverage_test_present",
        "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/HealthStateTests.swift",
        ("testUnknownAndPartialDomainStatusesDoNotBecomeUsableRecoveryEvidence",),
    ),
    (
        "narrative_unknown_coverage_test_present",
        "Packages/DensosoDomain/Tests/DensosoDomainTests/HealthNarrativeTests.swift",
        ("testNarrativeContextOmitsUnknownTrainingLoadZeroPlaceholders",),
    ),
)


def read_text(root: Path, relative: str) -> tuple[str | None, str | None]:
    path = root / relative
    if not path.is_file():
        return None, f"required source file is missing: {relative}"
    try:
        return path.read_text(encoding="utf-8"), None
    except (OSError, UnicodeError) as error:
        return None, f"cannot read {relative}: {type(error).__name__}"


def source_check(
    root: Path,
    check_id: str,
    relative: str,
    required: tuple[str, ...],
    forbidden: tuple[str, ...] = (),
) -> dict[str, Any]:
    content, issue = read_text(root, relative)
    if content is None:
        return {"id": check_id, "status": "BLOCKED", "evidenceLevel": "source", "reason": issue}
    missing = [item for item in required if item not in content]
    present_forbidden = [item for item in forbidden if item in content]
    if missing or present_forbidden:
        details = []
        if missing:
            details.append(f"missing required anchors ({len(missing)})")
        if present_forbidden:
            details.append(f"found forbidden anchors ({len(present_forbidden)})")
        return {
            "id": check_id,
            "status": "FAIL",
            "evidenceLevel": "source",
            "reason": "; ".join(details),
        }
    return {"id": check_id, "status": "PASS", "evidenceLevel": "source", "reason": "source anchors present"}


def test_presence_check(root: Path, check_id: str, relative: str, names: tuple[str, ...]) -> dict[str, Any]:
    content, issue = read_text(root, relative)
    if content is None:
        return {"id": check_id, "status": "BLOCKED", "evidenceLevel": "source", "reason": issue}
    missing = [name for name in names if name not in content]
    if missing:
        return {
            "id": check_id,
            "status": "FAIL",
            "evidenceLevel": "source",
            "reason": f"{len(missing)} required XCTest method name(s) are absent",
        }
    return {
        "id": check_id,
        "status": "PASS",
        "evidenceLevel": "source",
        "reason": "required XCTest methods are present; execution is reported separately",
    }


def aggregate_status(checks: list[dict[str, Any]]) -> str:
    statuses = {check.get("status") for check in checks}
    if "FAIL" in statuses:
        return "FAIL"
    if "BLOCKED" in statuses:
        return "BLOCKED"
    if "NOT_MEASURED" in statuses:
        return "NOT_MEASURED"
    if statuses == {"PASS"}:
        return "PASS"
    return "BLOCKED"


def git_head(root: Path) -> str | None:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--verify", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = result.stdout.strip().lower()
    return value if re.fullmatch(r"[0-9a-f]{40,64}", value) else None


def load_evidence(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "evidence manifest does not exist"
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        return None, f"cannot parse evidence manifest: {type(error).__name__}"
    if not isinstance(value, dict):
        return None, "evidence manifest root must be a JSON object"
    return value, None


def status_record(check_id: str, status: str, reason: str, **extra: Any) -> dict[str, Any]:
    return {"id": check_id, "status": status, "reason": reason, **extra}


def validate_manifest_header(
    evidence: dict[str, Any], expected_head: str | None
) -> tuple[str, dict[str, Any]]:
    issues: list[str] = []
    if isinstance(evidence.get("schemaVersion"), bool) or evidence.get("schemaVersion") != 1:
        issues.append("schemaVersion must equal 1")
    if evidence.get("gate") != GATE_ID:
        issues.append(f"gate must equal {GATE_ID}")
    head_sha = evidence.get("headSha")
    if not isinstance(head_sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40,64}", head_sha):
        issues.append("headSha must be a full hexadecimal commit id")
    elif expected_head is None:
        issues.append("cannot verify evidence headSha because the checkout HEAD is unavailable")
    elif head_sha.lower() != expected_head.lower():
        issues.append("evidence headSha does not match the checked-out HEAD")
    run_id = evidence.get("runId")
    if isinstance(run_id, bool) or not isinstance(run_id, (str, int)) or not str(run_id).strip():
        issues.append("runId is required")
    report = {
        "headSha": head_sha.lower() if isinstance(head_sha, str) else None,
        "runId": str(run_id) if not isinstance(run_id, bool) and isinstance(run_id, (str, int)) else None,
    }
    return ("FAIL" if any("does not match" in issue or "must equal" in issue or "must be" in issue or "is required" in issue for issue in issues) else "BLOCKED" if issues else "PASS"), {
        **report,
        "issues": issues,
    }


def validate_test_results(evidence: dict[str, Any] | None) -> list[dict[str, Any]]:
    if evidence is None:
        return [status_record("required_ci_test_execution", "BLOCKED", "no structured CI evidence manifest was supplied")]
    raw = evidence.get("testResults")
    if not isinstance(raw, dict):
        raw = {}
        missing_app_results = True
    else:
        missing_app_results = False
    package_raw = evidence.get("swiftPackageTestResults")
    if not isinstance(package_raw, dict):
        package_raw = {}
    combined_raw = {**raw, **package_raw}
    bad_entries = [
        name for name, value in combined_raw.items()
        if not isinstance(name, str) or not isinstance(value, str) or value not in STATUSES
    ]
    if bad_entries:
        return [status_record("required_ci_test_execution", "FAIL", "a test result map contains an invalid status value")]
    results: list[dict[str, Any]] = []
    for name in XCODE_REQUIRED_TESTS:
        status = raw.get(name)
        if status is None:
            status = "BLOCKED"
            reason = "app XCTest result is absent from testResults"
        elif status == "PASS":
            reason = "CI manifest reports this app XCTest as passed"
        elif status == "FAIL":
            reason = "CI manifest reports this app XCTest as failed"
        elif status == "BLOCKED":
            reason = "CI manifest reports this app XCTest as blocked or skipped"
        else:
            reason = "CI manifest reports no measurement for this app XCTest"
        if missing_app_results:
            reason = "testResults object is missing"
        results.append(status_record(name, status, reason, evidenceLevel="ci-test-result", testKind="xcodebuild"))
    for selector in SWIFT_PACKAGE_TEST_FILTERS:
        status = package_raw.get(selector)
        if status is None:
            status = "BLOCKED"
            reason = "Swift package test result is absent from swiftPackageTestResults"
        elif status == "PASS":
            reason = "CI manifest reports this Swift package XCTest as passed"
        elif status == "FAIL":
            reason = "CI manifest reports this Swift package XCTest as failed"
        elif status == "BLOCKED":
            reason = "CI manifest reports this Swift package XCTest as blocked or skipped"
        else:
            reason = "CI manifest reports no measurement for this Swift package XCTest"
        results.append(status_record(
            selector,
            status,
            reason,
            evidenceLevel="ci-test-result",
            testKind="swift-package",
            swiftTestFilter=selector,
        ))
    return results


def test_result_statuses(evidence: dict[str, Any] | None) -> dict[str, str]:
    if evidence is None:
        return {}
    app_results = evidence.get("testResults")
    package_results = evidence.get("swiftPackageTestResults")
    statuses: dict[str, str] = {}
    if isinstance(app_results, dict):
        statuses.update({key: value for key, value in app_results.items() if isinstance(key, str) and isinstance(value, str)})
    if isinstance(package_results, dict):
        statuses.update({key: value for key, value in package_results.items() if isinstance(key, str) and isinstance(value, str)})
    return statuses


def validate_behavior_check(
    check_id: str,
    raw: Any,
    evidence_head: str | None,
    test_statuses: dict[str, str],
    sanitized_provider_artifact_status: str | None = None,
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return status_record(check_id, "NOT_MEASURED", "no structured behavioral evidence was supplied", evidenceLevel="runtime-evidence")
    status = raw.get("status")
    if not isinstance(status, str) or status not in STATUSES:
        return status_record(check_id, "FAIL", "behavior check status must be PASS, FAIL, BLOCKED, or NOT_MEASURED", evidenceLevel="runtime-evidence")
    if status != "PASS":
        blocking_reason = raw.get("blockingReason")
        reason = blocking_reason if isinstance(blocking_reason, str) and blocking_reason.strip() else "evidence manifest reports this check without a passing result"
        return status_record(check_id, status, reason, evidenceLevel="runtime-evidence")

    missing_test_results = [test for test in BEHAVIOR_CHECKS[check_id].required_tests if test_statuses.get(test) != "PASS"]
    if missing_test_results:
        dependency_statuses = [test_statuses.get(test, "BLOCKED") for test in missing_test_results]
        if "FAIL" in dependency_statuses:
            dependency_status = "FAIL"
        elif "BLOCKED" in dependency_statuses:
            dependency_status = "BLOCKED"
        else:
            dependency_status = "NOT_MEASURED"
        return status_record(
            check_id,
            dependency_status,
            "required local semantic test result(s) are not PASS: " + ", ".join(missing_test_results),
            evidenceLevel="ci-test-result",
        )

    evidence_ref = raw.get("evidenceRef")
    if not isinstance(evidence_ref, str) or not evidence_ref.strip():
        return status_record(check_id, "FAIL", "PASS requires a non-empty evidenceRef", evidenceLevel="runtime-evidence")
    if check_id == "provider_final_request_body":
        if evidence_ref != SANITIZED_PROVIDER_REQUEST_ARTIFACT:
            return status_record(
                check_id,
                "FAIL",
                f"PASS must reference {SANITIZED_PROVIDER_REQUEST_ARTIFACT}",
                evidenceLevel="runtime-evidence",
            )
        if sanitized_provider_artifact_status != "PASS":
            status = sanitized_provider_artifact_status or "BLOCKED"
            reason = (
                "the runtime sanitized provider-request artifact is not verified"
                if status == "BLOCKED"
                else "the runtime sanitized provider-request artifact is invalid"
            )
            return status_record(check_id, status, reason, evidenceLevel="runtime-evidence")

    check = BEHAVIOR_CHECKS[check_id]
    missing = [field for field in check.required_true if raw.get(field) is not True]
    missing.extend(
        field for field, mode, required in check.required_numbers
        if not isinstance(raw.get(field), int)
        or (mode == "exact" and raw.get(field) != required)
        or (mode == "minimum" and raw.get(field) < required)
    )
    if check.require_providers:
        providers = raw.get("providers")
        if not isinstance(providers, list) or not all(isinstance(value, str) for value in providers) or set(providers) != PROVIDERS:
            missing.append("providers[deepSeek,qwen]")
    if check.require_health_classes:
        classes = raw.get("forbiddenClassesChecked")
        if not isinstance(classes, list) or not all(isinstance(value, str) for value in classes) or not HEALTH_CLASSES.issubset(set(classes)):
            missing.append("forbiddenClassesChecked[all health classes]")
    if check_id == "imported_backup_reconfirmation":
        explicit_reconfirmation = raw.get("requiresReconfirmation") is True
        backup_omits_policy_and_denies_by_default = (
            raw.get("policyTransferredInBackup") is False
            and raw.get("restoredConsentDefaultsDenied") is True
        )
        if not explicit_reconfirmation and not backup_omits_policy_and_denies_by_default:
            missing.append(
                "requiresReconfirmation=true or policyTransferredInBackup=false+restoredConsentDefaultsDenied=true"
            )
    if check_id == "health_window":
        initial_days = raw.get("initialBackfillDays")
        if isinstance(initial_days, bool) or not isinstance(initial_days, int) or initial_days < 0:
            missing.append("initialBackfillDays[non-negative integer]")
        elif initial_days < 42:
            boundary_kind = raw.get("boundaryKind")
            boundary_start = raw.get("boundaryStart")
            if not isinstance(boundary_kind, str) or boundary_kind not in {"authorization", "dataAvailability"} \
                    or not isinstance(boundary_start, str) or not boundary_start.strip():
                missing.append("boundaryKind[authorization|dataAvailability]+boundaryStart when initialBackfillDays<42")
    if missing:
        return status_record(
            check_id,
            "FAIL",
            "PASS claim lacks required fields: " + ", ".join(missing),
            evidenceLevel="runtime-evidence",
            evidenceReferencePresent=True,
        )
    if evidence_head is None:
        return status_record(check_id, "BLOCKED", "cannot bind behavioral evidence to a verified commit", evidenceLevel="runtime-evidence")
    return status_record(
        check_id,
        "PASS",
        "structured evidence fields satisfy the check contract",
        evidenceLevel="runtime-evidence",
        evidenceReferencePresent=True,
    )


def validate_sanitized_provider_request_artifact(
    path: Path | None,
    *,
    evidence_head: str | None,
    test_statuses: dict[str, str],
) -> dict[str, Any]:
    if path is None:
        return status_record(
            "sanitized_provider_request_artifact",
            "BLOCKED",
            "the exported XCTest attachment was not supplied",
            evidenceLevel="runtime-evidence",
        )
    if path.name != SANITIZED_PROVIDER_REQUEST_ARTIFACT:
        return status_record(
            "sanitized_provider_request_artifact",
            "FAIL",
            f"artifact filename must be {SANITIZED_PROVIDER_REQUEST_ARTIFACT}",
            evidenceLevel="runtime-evidence",
        )
    class DuplicateJSONKeyError(ValueError):
        pass

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise DuplicateJSONKeyError
            result[key] = value
        return result

    try:
        encoded = path.read_bytes()
        artifact = json.loads(encoded.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except FileNotFoundError:
        return status_record(
            "sanitized_provider_request_artifact",
            "BLOCKED",
            "the exported XCTest attachment is missing",
            evidenceLevel="runtime-evidence",
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        return status_record(
            "sanitized_provider_request_artifact",
            "FAIL",
            f"the exported XCTest attachment is not valid UTF-8 JSON ({type(error).__name__})",
            evidenceLevel="runtime-evidence",
        )
    except DuplicateJSONKeyError:
        return status_record(
            "sanitized_provider_request_artifact",
            "FAIL",
            "the exported XCTest attachment contains duplicate JSON object keys",
            evidenceLevel="runtime-evidence",
        )

    required_fields = {
        "schemaVersion",
        "gate",
        "testMethod",
        "captureSource",
        "rawRequestBodyIncluded",
        "sentinelValuesIncluded",
        "observations",
    }
    if not isinstance(artifact, dict) or set(artifact) != required_fields:
        return status_record(
            "sanitized_provider_request_artifact",
            "FAIL",
            "the attachment has unexpected or missing fields; raw request content is not permitted",
            evidenceLevel="runtime-evidence",
        )
    if (
        isinstance(artifact.get("schemaVersion"), bool)
        or artifact.get("schemaVersion") != 1
        or artifact.get("gate") != GATE_ID
        or artifact.get("testMethod") != SANITIZED_PROVIDER_REQUEST_TEST
        or artifact.get("captureSource") != "scripted-local-http-transport"
        or artifact.get("rawRequestBodyIncluded") is not False
        or artifact.get("sentinelValuesIncluded") is not False
    ):
        return status_record(
            "sanitized_provider_request_artifact",
            "FAIL",
            "the attachment header is invalid or does not declare a sanitized local transport capture",
            evidenceLevel="runtime-evidence",
        )
    observations = artifact.get("observations")
    if not isinstance(observations, list):
        return status_record(
            "sanitized_provider_request_artifact",
            "FAIL",
            "observations must be a JSON array",
            evidenceLevel="runtime-evidence",
        )
    observation_fields = {
        "provider",
        "deniedHealthClass",
        "requestCaptured",
        "requestBodyByteCount",
        "forbiddenSentinelCount",
        "forbiddenSentinelMatchCount",
        "forbiddenSentinelsAbsent",
        "allowedCategoryControlPresent",
        "rootMessageSentinelAbsent",
        "conditionalDerivedSentinelsAbsent",
    }
    expected_pairs = {(provider, health_class) for provider in PROVIDERS for health_class in HEALTH_CLASSES}
    observed_pairs: set[tuple[str, str]] = set()
    for observation in observations:
        if not isinstance(observation, dict) or set(observation) != observation_fields:
            return status_record(
                "sanitized_provider_request_artifact",
                "FAIL",
                "an observation has unexpected or missing fields; request bodies and sentinels are forbidden",
                evidenceLevel="runtime-evidence",
            )
        provider = observation.get("provider")
        health_class = observation.get("deniedHealthClass")
        if (
            not isinstance(provider, str)
            or provider not in PROVIDERS
            or not isinstance(health_class, str)
            or health_class not in HEALTH_CLASSES
        ):
            return status_record(
                "sanitized_provider_request_artifact",
                "FAIL",
                "an observation names an unsupported provider or health class",
                evidenceLevel="runtime-evidence",
            )
        pair = (provider, health_class)
        if pair in observed_pairs:
            return status_record(
                "sanitized_provider_request_artifact",
                "FAIL",
                "the attachment contains duplicate provider/class observations",
                evidenceLevel="runtime-evidence",
            )
        observed_pairs.add(pair)
        body_size = observation.get("requestBodyByteCount")
        expected_sentinel_count = observation.get("forbiddenSentinelCount")
        sentinel_match_count = observation.get("forbiddenSentinelMatchCount")
        if (
            observation.get("requestCaptured") is not True
            or isinstance(body_size, bool)
            or not isinstance(body_size, int)
            or body_size <= 0
            or isinstance(expected_sentinel_count, bool)
            or not isinstance(expected_sentinel_count, int)
            or expected_sentinel_count <= 0
            or isinstance(sentinel_match_count, bool)
            or not isinstance(sentinel_match_count, int)
            or sentinel_match_count < 0
        ):
            return status_record(
                "sanitized_provider_request_artifact",
                "BLOCKED",
                "an observation does not prove that a non-empty serialized request was captured",
                evidenceLevel="runtime-evidence",
            )
        if any(
            observation.get(field) is not True
            for field in (
                "forbiddenSentinelsAbsent",
                "allowedCategoryControlPresent",
                "rootMessageSentinelAbsent",
                "conditionalDerivedSentinelsAbsent",
            )
        ):
            return status_record(
                "sanitized_provider_request_artifact",
                "FAIL",
                f"the runtime request observation failed its privacy control for {provider}/{health_class}",
                evidenceLevel="runtime-evidence",
            )
        if sentinel_match_count != 0:
            return status_record(
                "sanitized_provider_request_artifact",
                "FAIL",
                f"the runtime request contains {sentinel_match_count} forbidden sentinel matches for {provider}/{health_class}",
                evidenceLevel="runtime-evidence",
            )

    if observed_pairs != expected_pairs:
        missing = sorted(expected_pairs - observed_pairs)
        return status_record(
            "sanitized_provider_request_artifact",
            "BLOCKED",
            f"provider/class coverage is incomplete ({len(missing)} of {len(expected_pairs)} observations missing)",
            evidenceLevel="runtime-evidence",
            missingObservationCount=len(missing),
        )
    if evidence_head is None:
        return status_record(
            "sanitized_provider_request_artifact",
            "BLOCKED",
            "the attachment cannot be bound to a verified CI evidence commit",
            evidenceLevel="runtime-evidence",
        )
    producer_test_status = test_statuses.get(SANITIZED_PROVIDER_REQUEST_TEST_METHOD, "BLOCKED")
    if producer_test_status != "PASS":
        return status_record(
            "sanitized_provider_request_artifact",
            "FAIL" if producer_test_status == "FAIL" else "BLOCKED",
            "the XCTest that emitted this attachment did not pass in the current run",
            evidenceLevel="runtime-evidence",
            producerTestStatus=producer_test_status,
        )
    return status_record(
        "sanitized_provider_request_artifact",
        "PASS",
        "the current-run XCTest attachment contains sanitized captured-request results for every provider and denied health class",
        evidenceLevel="runtime-evidence",
        sha256=hashlib.sha256(encoded).hexdigest(),
        headSha=evidence_head.lower(),
        producerTestStatus=producer_test_status,
        observationCount=len(observations),
        providers=sorted(PROVIDERS),
        forbiddenHealthClasses=sorted(HEALTH_CLASSES),
        rawRequestBodyIncluded=False,
        sentinelValuesIncluded=False,
    )


def build_report(
    root: Path,
    evidence_path: Path | None,
    expected_head: str | None,
    sanitized_provider_artifact_path: Path | None = None,
) -> dict[str, Any]:
    source_checks = [source_check(root, *contract) for contract in SOURCE_CONTRACTS]
    source_checks.extend(test_presence_check(root, *contract) for contract in TEST_FILE_CONTRACTS)

    evidence: dict[str, Any] | None = None
    manifest_result: dict[str, Any]
    if evidence_path is None:
        manifest_result = status_record(
            "evidence_manifest",
            "BLOCKED",
            "no structured CI evidence manifest was supplied",
            evidenceLevel="ci-evidence",
        )
    else:
        evidence, issue = load_evidence(evidence_path)
        if issue:
            manifest_result = status_record("evidence_manifest", "FAIL", issue, evidenceLevel="ci-evidence")
        else:
            assert evidence is not None
            header_status, header = validate_manifest_header(evidence, expected_head)
            manifest_result = status_record(
                "evidence_manifest",
                header_status,
                "; ".join(header["issues"]) if header["issues"] else "manifest header and commit identity are valid",
                evidenceLevel="ci-evidence",
            )
            if header_status in {"FAIL", "BLOCKED"}:
                evidence = None

    evidence_head = evidence.get("headSha") if evidence is not None else None
    current_test_statuses = test_result_statuses(evidence)
    sanitized_provider_artifact = validate_sanitized_provider_request_artifact(
        sanitized_provider_artifact_path,
        evidence_head=evidence_head if isinstance(evidence_head, str) else None,
        test_statuses=current_test_statuses,
    )
    test_checks = validate_test_results(evidence)
    behavior_values = evidence.get("behaviorChecks", {}) if evidence is not None else {}
    if not isinstance(behavior_values, dict):
        behavior_values = {}
        behavior_checks = [status_record("behavior_evidence_manifest", "FAIL", "behaviorChecks must be a JSON object", evidenceLevel="ci-evidence")]
    else:
        behavior_checks = [
            validate_behavior_check(
                check_id,
                behavior_values.get(check_id),
                evidence_head if isinstance(evidence_head, str) else None,
                current_test_statuses,
                sanitized_provider_artifact["status"] if check_id == "provider_final_request_body" else None,
            )
            for check_id in BEHAVIOR_CHECKS
        ]
        unknown_ids = sorted(set(behavior_values) - set(BEHAVIOR_CHECKS))
        if unknown_ids:
            behavior_checks.append(
                status_record(
                    "unknown_behavior_check_ids",
                    "FAIL",
                    f"behaviorChecks contains {len(unknown_ids)} unknown check id(s)",
                    evidenceLevel="ci-evidence",
                )
            )

    checks = source_checks + [manifest_result] + test_checks + behavior_checks + [sanitized_provider_artifact]
    overall = aggregate_status(checks)
    expected_head_sha = expected_head or git_head(root)
    summary = {
        "total": len(checks),
        "PASS": sum(check["status"] == "PASS" for check in checks),
        "FAIL": sum(check["status"] == "FAIL" for check in checks),
        "BLOCKED": sum(check["status"] == "BLOCKED" for check in checks),
        "NOT_MEASURED": sum(check["status"] == "NOT_MEASURED" for check in checks),
    }
    return {
        "schemaVersion": 1,
        "gate": GATE_ID,
        "status": overall,
        "headSha": expected_head_sha,
        "evidenceManifestSupplied": evidence_path is not None,
        "testExecutionContract": {
            "xcodebuildResultField": "testResults",
            "requiredXCTestMethods": list(XCODE_REQUIRED_TESTS),
            "swiftPackageResultField": "swiftPackageTestResults",
            "requiredSwiftPackageFilters": list(SWIFT_PACKAGE_TEST_FILTERS),
            "swiftPackageTestFilters": list(SWIFT_PACKAGE_TEST_FILTERS),
            "runtimeCoverageBehaviorRequiresAllListedTestsPass": True,
        },
        "sanitizedProviderRequestArtifact": sanitized_provider_artifact,
        "liveHealthKitAuthorizationBoundary": {
            "status": "NOT_MEASURED",
            "reason": (
                "No signed-device authorization matrix was supplied. The software contract tests verify "
                "bounded 42-day rebuilding, explicit unknown coverage, and coordinator behavior when a "
                "boundary is available; the production adapter does not depend on Apple's Beta boundary API."
            ),
            "evidenceLevel": "device-evidence",
        },
        "checks": checks,
        "summary": summary,
        "limitations": [
            "Source-anchor PASS means only that expected code markers exist; it does not prove runtime enforcement.",
            "XCTest PASS is reported from the supplied CI manifest and is not rerun by this validator.",
            "Swift package XCTest results are read from swiftPackageTestResults using exact Suite/testMethod filter keys.",
            "The sanitized provider-request attachment is opened and checked for its exact schema and all provider/class observations; no raw request body or sentinel values are retained.",
            "Adapter-body XCTest captures the locally serialized URLRequest before transport; it cannot prove what a live remote service received.",
            "Live HealthKit limited-history authorization behavior is reported separately as NOT_MEASURED; simulator/fake-provider tests do not establish a signed-device boundary.",
            "A clean Gate 19 PASS requires executed tests and explicit behavioral evidence for every listed runtime check.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (defaults to this script's repository)")
    parser.add_argument("--evidence", type=Path, help="structured CI evidence manifest JSON")
    parser.add_argument("--head-sha", help="expected full commit id; otherwise the checked-out HEAD is used")
    parser.add_argument(
        "--sanitized-provider-request-artifact",
        type=Path,
        help="sanitized request-evidence JSON exported from the current Gate 19 xcresult bundle",
    )
    parser.add_argument("--report", type=Path, help="write the JSON report to this path")
    args = parser.parse_args()

    root = args.root.resolve()
    expected_head = args.head_sha.lower() if args.head_sha else git_head(root)
    if expected_head is not None and not re.fullmatch(r"[0-9a-f]{40,64}", expected_head):
        parser.error("--head-sha must be a full hexadecimal commit id")
    evidence_path = args.evidence.resolve() if args.evidence else None
    report = build_report(root, evidence_path, expected_head, args.sanitized_provider_request_artifact)
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.report:
        try:
            destination = args.report.resolve()
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(encoded, encoding="utf-8")
        except OSError as error:
            print(json.dumps({"status": "FAIL", "error": f"cannot write report: {type(error).__name__}"}), file=sys.stderr)
            return 1
    print(encoded, end="")
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 2, "NOT_MEASURED": 2}[report["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
