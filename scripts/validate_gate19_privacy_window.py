#!/usr/bin/env python3
"""Validate Gate 19 source contracts and structured CI evidence.

Usage:
  python scripts/validate_gate19_privacy_window.py \
      --evidence artifacts/gate19-evidence.json \
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
manifest must bind to the checked-out HEAD. References should point to
sanitized, non-PHI artifacts. This validator checks manifest structure and
source anchors; it does not independently execute XCTest or inspect provider
traffic. An adapter test may inspect a locally serialized URLRequest body
through a scripted transport; that does not prove what a live remote service
received. A PASS in the manifest remains a claim backed by external evidence.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
GATE_ID = "gate-19-cloud-health-privacy-window"
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
    "testDeniedHealthClassSentinelsAreAbsentFromSerializedProviderContinuationBodies",
    "testPolicyRevocationDuringHealthToolExecutionFiltersTheContinuationRequest",
    "testBackupDoesNotTransferCloudHealthConsentAndRestoreDefaultsToDenied",
    "testInitialHealthKitBackfillUsesTheSame42DayWindowForEveryStreamType",
    "testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays",
    "testAuthorizationBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor",
    "testObserverBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor",
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
        required_true=("forbiddenSentinelsAbsent",),
        require_providers=True,
        require_health_classes=True,
    ),
    "provider_tool_output": BehaviorCheck(
        required_true=("forbiddenSentinelsAbsent", "derivedMetricsChecked"),
        require_providers=True,
        require_health_classes=True,
    ),
    "cached_and_continued_context": BehaviorCheck(
        required_true=("forbiddenSentinelsAbsent", "policyChangeApplied"),
        require_providers=True,
        require_health_classes=True,
    ),
    "consent_expansion_confirmation": BehaviorCheck(
        required_true=("expansionRequiresConfirmation", "automaticExpansionDenied"),
        require_providers=True,
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
            "testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays",
            "testAuthorizationBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor",
            "testObserverBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor",
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
            "var isHealthContextClass: Bool",
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
        "consent_storage_key_is_provider_and_class_scoped",
        "Densoso/Infrastructure/Persistence/SwiftDataProviderGovernanceRepository.swift",
        (
            "func isConsentGranted(provider: ProviderID, dataClass: ProviderDataClass)",
            "func setConsent(",
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
        "cloud_health_policy_tests_present",
        "DensosoTests/Application/CloudHealthContextPolicyTests.swift",
        (
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
        ),
    ),
    (
        "health_window_sync_tests_present",
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        (
            "testInitialHealthKitBackfillUsesTheSame42DayWindowForEveryStreamType",
            "testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays",
            "testAuthorizationBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor",
            "testObserverBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor",
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
        (),
    ),
    (
        "recent_workout_repository_unknown_state_test_present",
        "DensosoTests/Application/GetRecentWorkoutsToolTests.swift",
        ("testRepositoryOmitsHealthKitWorkoutsWithUnknownOrMissingReadState",),
        (),
    ),
    (
        "unknown_aggregate_projection_test_present",
        "DensosoTests/HealthRepositoryTests.swift",
        ("testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue",),
        (),
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
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        return status_record(check_id, "NOT_MEASURED", "no structured behavioral evidence was supplied", evidenceLevel="runtime-evidence")
    status = raw.get("status")
    if not isinstance(status, str) or status not in STATUSES:
        return status_record(check_id, "FAIL", "behavior check status must be PASS, FAIL, BLOCKED, or NOT_MEASURED", evidenceLevel="runtime-evidence")
    if status != "PASS":
        return status_record(check_id, status, "evidence manifest reports this check without a passing result", evidenceLevel="runtime-evidence")

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
        "structured evidence fields satisfy the check contract; artifact contents are not inspected",
        evidenceLevel="runtime-evidence",
        evidenceReferencePresent=True,
    )


def build_report(root: Path, evidence_path: Path | None, expected_head: str | None) -> dict[str, Any]:
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
                evidence.get("headSha") if evidence else None,
                test_result_statuses(evidence),
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

    checks = source_checks + [manifest_result] + test_checks + behavior_checks
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
        "checks": checks,
        "summary": summary,
        "limitations": [
            "Source-anchor PASS means only that expected code markers exist; it does not prove runtime enforcement.",
            "XCTest PASS is reported from the supplied CI manifest and is not rerun by this validator.",
            "Swift package XCTest results are read from swiftPackageTestResults using exact Suite/testMethod filter keys.",
            "Behavior evidence references and asserted fields are schema-validated, but referenced artifact contents are not opened or independently verified.",
            "Adapter-body XCTest captures the locally serialized URLRequest before transport; it cannot prove what a live remote service received.",
            "A clean Gate 19 PASS requires executed tests and explicit behavioral evidence for every listed runtime check.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (defaults to this script's repository)")
    parser.add_argument("--evidence", type=Path, help="structured CI evidence manifest JSON")
    parser.add_argument("--head-sha", help="expected full commit id; otherwise the checked-out HEAD is used")
    parser.add_argument("--report", type=Path, help="write the JSON report to this path")
    args = parser.parse_args()

    root = args.root.resolve()
    expected_head = args.head_sha.lower() if args.head_sha else git_head(root)
    if expected_head is not None and not re.fullmatch(r"[0-9a-f]{40,64}", expected_head):
        parser.error("--head-sha must be a full hexadecimal commit id")
    evidence_path = args.evidence.resolve() if args.evidence else None
    report = build_report(root, evidence_path, expected_head)
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
