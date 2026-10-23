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
    normalized_content = " ".join(content.split())
    for needle in needles:
        if " ".join(needle.split()) not in normalized_content:
            errors.append(f"{relative} is missing {needle}")
    return content


def gate_contract(gate: int, errors: list[str]) -> str:
    if gate == 11:
        require(
            "docs/gates/gate-11-ai-native-health-loop.md",
            (
                "Gate 11",
                "effective historical profiles",
                "HealthRepositoryTests.testInsertAndDeleteReprojectsTheSameDay",
                "HealthRepositoryTests.testConfirmedFoodHistoryRepositoryPagesMealsAndDeduplicatesFoodIDs",
                "HealthRepositoryTests.testProjectionUsesEffectiveProfileAndHistoricalWeightWithoutBorrowingFutureData",
                "HealthRepositoryTests.testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion",
                "HealthKitSyncCoordinatorTests.testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",
                "HealthKitSyncCoordinatorTests.testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder",
                "HealthKitSyncCoordinatorTests.testOneFailedStreamDoesNotBlockOtherHealthMetrics",
                "HealthSyncOutboxWorkerTests.testRetryReusesStableSyncIdentifierAndVersion",
                "HealthSyncOutboxWorkerTests.testInterruptedSendingEntryIsRecoveredAndRetried",
                "HealthSyncOutboxWorkerTests.testInterruptedOutboxRecoveryAndProcessingPagePastBoundedBatch",
                "BriefNotificationSchedulerTests.testNotificationErrorsExposeSharedSafeDescriptors",
                "HealthRepositoryTests.testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches",
                "HealthRepositoryTests.testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable",
                "HealthRepositoryTests.testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown",
                "HealthRepositoryTests.testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays",
                "HealthRepositoryTests.testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner",
                "ConfirmationCoordinatorTests.testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision",
                "ConfirmationCoordinatorTests.testHistoricalConfirmationKeepsPendingMetricsWhenProfileAndWeightAreMissing",
                "SharedErrorDescriptorTests",
                "HistoricalMetricsRecomputeServiceTests.testRecomputesOnlyExistingEligiblePendingMetricsWithinBatch",
                "HistoricalMetricsRecomputeServiceTests.testMissingDOBDoesNotLetObservedEnergyClearRecomputeFlag",
                "HistoricalMetricsRecomputeServiceTests.testOrdinaryHistoricalReprojectKeepsPendingFlagWhenDOBMissingWithObservedEnergy",
                "HistoricalMetricsRecomputeServiceTests.testCurrentDayReprojectRetainsObservedEnergyBehaviorWithoutProfileOrWeight",
                "HistoricalMetricsRecomputeServiceTests.testNewHistoricalProjectionWithoutRequiredInputsIsPersistedAsPending",
                "HistoricalMetricsRecomputeServiceTests.testCurrentDayUsesProfileAndWeightAddedAfterMidnight",
                "HistoricalMetricsRecomputeServiceTests.testHistoricalProjectionUsesProfileAndWeightEffectiveLaterThatDay",
                "HistoricalMetricsRecomputeServiceTests.testProjectionReferenceUsesTodayAndHistoricalDayEndAcrossDST",
                "HistoricalMetricsRecomputeServiceTests.testMissingWeightDoesNotLetObservedEnergyClearRecomputeFlag",
                "HistoricalMetricsRecomputeServiceTests.testCancellationStopsAfterSavedRowAndReportsRetryableWork",
                "most recent 90 local days",
                "complete HealthKit basal/active values cannot bypass",
                "each completed row before continuing",
                "Remaining eligible days request an",
                "Ordinary reprojects also apply the policy to new",
                "Both projection entry points share the same fingerprint comparison",
                "Daily-brief cache versions",
                "local day key and time zone",
                "source fingerprint",
                "per-metric observed/estimated/partial/unavailable/pending",
                "fresh for six hours",
                "Legacy snapshots decode with",
                "CaloricEnergySemanticsTests.testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics",
                "DailyMetricsProjectionFingerprintTests.testUnchangedFingerprintSkipsWriteButPendingLegacyMetricIsReprojected",
                "DailyMetricsProjectionFingerprintTests.testSourceCursorProfileAndGoalRevisionsChangeProjectionFingerprint",
                "DailyMetricsProjectionFingerprintTests.testUnrelatedHealthKitCursorDoesNotInvalidateDailyMetricsProjection",
                "DailyMetricsProjectionFingerprintTests.testWorkoutEnergyAndProvenanceChangesProjectionFingerprint",
                "HealthIntelligenceTests.testHealthContextAveragesSignedEnergyBalanceAndReportsItsDenominator",
                "DailyLoopSnapshotTests.testMainPRAlgorithmVersionsAreCentralizedAndInvalidateDailyBriefCache",
                "DailyLoopSnapshotTests.testLegacySnapshotDecodesWithUnknownProvenanceAndRefreshRequiredState",
                "HealthIntelligenceServiceTests.testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash",
                "HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches",
                "HealthProjectionActorTests",
                "HealthProjectionActorTests.testStateRefreshReportsP50P95ForFortyTwoDayLocalDataWindow",
                "DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState",
                "DailyLoopSnapshotCompositionTests.testComposerMarksOldHealthBriefStaleAndChangesFingerprintWithItsSource",
                "DailyLoopSnapshotCompositionTests.testComposerCarriesSafeErrorStateWithoutPublishingHealthFingerprint",
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
            "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/DailyHealthSampleSummaryTests.swift",
            (
                "testDailySnapshotEncodingKeepsOnlySummaryAndDropsRawSamples",
                "testSleepAggregationRetainsWatchPriorityAndLegacyCategoryAliases",
                "testSampleDeduplicationUsesSyncVersionThenStableTieOrder",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/HealthStateTests.swift",
            ("testMissingSleepVitalsAndTrainingLoadRemainUnknown",),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/DailyLoopSnapshotTests.swift",
            (
                "testSnapshotSupportsUnavailableOptionalSummaries",
                "testMainPRAlgorithmVersionsAreCentralizedAndInvalidateDailyBriefCache",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Sources/DensosoDomain/AlgorithmVersions.swift",
            (
                'public static let calorieAccounting = "calorie-accounting-v2"',
                'public static let dailyMetricsProjection = "daily-metrics-projection-v1"',
                'public static let mealEstimator = "meal-estimator-v2"',
                'public static let portionEstimator = "portion-estimator-v2"',
                'public static let healthIntelligence = "health-intelligence-v2"',
                'public static let recommendationPolicy = "recommendation-policy-v1"',
                'public static let dailyLoop = "daily-loop-v2"',
            ),
            errors,
        )
        require(
            "Densoso/Services/DailyMetricsProjectionFingerprint.swift",
            (
                "struct DailyMetricsProjectionFingerprintContext",
                "healthKitCursorRevisions",
                "$0.profileKey == profileKey && $0.effectiveFrom <= effectiveAt",
                "cursor.lastSuccessfulAt",
                "cursor.lookbackStart",
                "SHA256",
                "static func isCurrent(",
                "!requiresRecompute",
                "AlgorithmVersions.dailyMetricsProjection",
            ),
            errors,
        )
        require(
            "DensosoTests/DailyMetricsProjectionFingerprintTests.swift",
            (
                "testUnchangedFingerprintSkipsWriteButPendingLegacyMetricIsReprojected",
                "testSourceCursorProfileAndGoalRevisionsChangeProjectionFingerprint",
                "testUnrelatedHealthKitCursorDoesNotInvalidateDailyMetricsProjection",
                "testWorkoutEnergyAndProvenanceChangesProjectionFingerprint",
                "DailyMetricsProjector.reproject(on: day, in: context)",
            ),
            errors,
        )
        require(
            "Densoso/Services/CaloricEngine.swift",
            (
                "estimated:\\($0.estimatedCaloriesBurned)",
                "intensity:\\($0.intensity)",
                "origin:\\($0.workoutOrigin)",
                "energy-source:\\($0.energySource ?? \"none\")",
                "projectionVersion: fingerprintContext.algorithmVersion",
            ),
            errors,
        )
        require(
            "Densoso/Services/DailyMetricsProjectionFingerprint.swift",
            (
                "target-weight:\\($0.targetWeightKilograms ?? -1)",
                "daily-deficit:\\($0.dailyDeficitKcal ?? -1)",
                "daily-protein:\\($0.dailyProteinGrams ?? -1)",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/SharedErrorDescriptorTests.swift",
            (
                "testStandardErrorCodesMatchMainPR109Contract",
                "testHealthKitDescriptorUsesGenericUserMessageAndHidesRawDetail",
                "testWatchDescriptorHidesCollidingMessageIdentifier",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Sources/DensosoDomain/SharedErrorDescriptor.swift",
            (
                "public enum SharedErrorCode: String, Codable, CaseIterable, Sendable",
                'case workoutKitUnauthorized = "WorkoutKitUnauthorized"',
                "public var diagnosticSafeDetail: String",
                "public protocol SharedErrorDescribing: LocalizedError",
            ),
            errors,
        )
        require(
            "Densoso/Views/ChatScreen.swift",
            (
                "private var dailyLoopSnapshotReadError: String?",
                "private var isLoadingDailyLoopSnapshot = true",
                "guard !isRefreshingDailyLoopSnapshot else { return }",
                "isLoadingDailyLoopSnapshot = true",
                "isLoadingDailyLoopSnapshot = false",
                "errorMessage: dailyLoopSnapshotReadError",
                "isLoading: isLoadingDailyLoopSnapshot",
                "dailyLoopSnapshotReadError = nil",
                "读取今日概览失败：",
                "SharedErrorDescriptor.mapped(",
                "fallback: .projectionFailedFallback",
                "onChange(of: dependencies.healthIntelligenceService.dailyBriefSourceFingerprint)",
                "refreshDailyLoopSnapshot(refreshHealth: true)",
                "refreshSnapshot()",
                "errorCode: descriptor.code.rawValue",
            ),
            errors,
        )
        require(
            "Densoso/App/DensosoApp.swift",
            ('PerformanceSignposts.event("App.LaunchStart")',),
            errors,
        )
        require(
            "Densoso/Views/Components/DailyLoopSnapshotCard.swift",
            (
                "let errorMessage: String?",
                "let isLoading: Bool",
                "let onRetry: () -> Void",
                "if isLoading {",
                "ProgressView(\"正在读取今日概览…\")",
                "今日概览读取失败",
                'Button("重试", action: onRetry)',
                "今日状态暂不可用",
                "snapshot.refreshState == .stale || snapshot.refreshState == .refreshRequired",
                "coverageSection(snapshot.coverage)",
                "availabilityName(_ availability: MetricAvailability)",
            ),
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
                "encodedToolError(descriptor: descriptor)",
                "fallback: .providerUnavailableFallback",
            ),
            errors,
        )
        require(
            "Densoso/Agent/ToolRegistry.swift",
            (
                "enum ToolError: Equatable, Sendable, SharedErrorDescribing",
                "code: .toolArgumentsInvalid",
                "reason: .invalidToolArguments",
                "sharedErrorDescriptor.userMessage",
            ),
            errors,
        )
        require(
            "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
            (
                "private func safeWatchErrorMessage(_ error: Error) -> String",
                "SharedErrorDescriptor.mapped(from: error, fallback: .watchUnavailableFallback)",
                "error.map(safeWatchErrorMessage)",
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
                "func confirmedPlanEntries() throws -> ConfirmedDailyLoopPlans",
                "private static let confirmedPlanFetchBatchSize = 64",
                "loadConfirmedPlanEntries(asOf: date)",
                "descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize",
                "descriptor.fetchOffset = offset",
                "HealthIntelligenceReadModel(calendar: calendar)",
            ),
            errors,
        )
        require(
            "Densoso/Services/HealthIntelligenceService.swift",
            (
                "func refresh(asOf date: Date = Date()) async throws -> DailyHealthBrief?",
                "try await projectionActor.refresh(asOf: date)",
                "PerformanceSignposts.measureAsync(\"Health.StateRefresh\")",
                "if snapshot.updatesWeeklyBrief",
                "fallback: .projectionFailedFallback",
                "lastError = \"无法更新健康摘要：\\(errorMessage)\"",
            ),
            errors,
        )
        background_scheduler = require(
            "Densoso/Application/DailyLoop/DailyLoopBackgroundScheduler.swift",
            (
                "guard let backgroundTask = taskBox.task else {",
                "backgroundTask.expirationHandler = { [taskBox, refreshOperation] in",
                "taskBox.expire {",
                "guard taskBox.canCancelActiveRefresh else { return }",
                "refreshOperation.cancel()",
                "activeRefreshTask = refreshOperation",
                "HistoricalMetricsRecomputing",
                "historicalMetricsRecomputer.recomputePendingMetrics(",
                "if recomputeResult.hasMoreEligibleWork",
                "earliestBeginInterval: Self.historicalRecomputeRetryInterval",
                "private static let projectionFailureFallback = SharedErrorDescriptor(",
                "self.lastError = SharedErrorDescriptor.mapped(",
                "fallback: Self.projectionFailureFallback",
                ".diagnosticSafeDetail",
                "guard !Task.isCancelled, !taskBox.isExpired else {",
                "await self.notificationScheduler.updateSnapshot(snapshot)",
                "self.watchConnectivityCoordinator.refreshApplicationContext()",
                "taskBox.complete(success: succeeded)",
                "private var expired = false",
                "private var completed = false",
                "let task: BGAppRefreshTask?",
                "private let completion: (Bool) -> Void",
                "let finalSuccess = success && !expired",
                "func markExpired() -> Bool",
                "return expired && !completed",
                "func expire(scheduleCancellation: () -> Void)",
                "guard markExpired() else { return }",
                "init(completion: @escaping (Bool) -> Void)",
            ),
            errors,
        )
        cancellation_guard = "guard !Task.isCancelled, !taskBox.isExpired else {"
        if background_scheduler.count(cancellation_guard) < 6:
            errors.append("Background refresh must recheck cancellation before work and after each awaited stage")
        for await_step in (
            "let syncResult = try await self.healthSyncCoordinator.syncAvailableData(using: repository)",
            "let recomputeResult = try await self.historicalMetricsRecomputer.recomputePendingMetrics(",
            "_ = try await self.healthIntelligenceService.refresh()",
            "let snapshot = try await self.dailyLoopSnapshotService.snapshot()",
            "await self.notificationScheduler.updateSnapshot(snapshot)",
        ):
            step_start = background_scheduler.find(await_step)
            check_start = background_scheduler.find(cancellation_guard, step_start + len(await_step))
            maximum_cancellation_gap = 700 if "recomputePendingMetrics" in await_step else 320
            if step_start < 0 or check_start < 0 or check_start - step_start > maximum_cancellation_gap:
                errors.append(f"Background refresh must check cancellation after {await_step}")
        expiration_handler = background_scheduler.split("backgroundTask.expirationHandler = {", 1)[-1]
        if "taskBox.expire {" not in expiration_handler or "refreshOperation.cancel()" not in expiration_handler:
            errors.append("Background refresh expiration must pass through the idempotent seam and cancel its own task")
        if "activeRefreshTask?.cancel()" in background_scheduler:
            errors.append("A stale expiration callback must not cancel whichever refresh is currently active")
        if background_scheduler.find("activeRefreshTask = refreshOperation") > background_scheduler.find(
            "backgroundTask.expirationHandler ="
        ):
            errors.append("The expiration handler must capture the exact refresh operation before it can expire")
        watch_refresh = background_scheduler.find("self.watchConnectivityCoordinator.refreshApplicationContext()")
        completion_report = background_scheduler.find("taskBox.complete(success: succeeded)")
        if watch_refresh < 0 or completion_report < watch_refresh or cancellation_guard not in background_scheduler[
            watch_refresh + len("self.watchConnectivityCoordinator.refreshApplicationContext()"):completion_report
        ]:
            errors.append("Background refresh must report completion only after the Watch update and cancellation check")
        require(
            "DensosoTests/Application/DailyLoopBackgroundSchedulerTests.swift",
            (
                "testExpirationAndCompletionAreIdempotentAndLateExpirationDoesNotCancelNextWork",
                "taskBox.expire",
                "taskBox.complete(success: true)",
                "XCTAssertEqual(reportedResults, [false])",
                "XCTAssertEqual(scheduledCancellations, 1)",
                "XCTAssertEqual(completedFirstResults, [true])",
                "XCTAssertEqual(lateCancellations, 0)",
            ),
            errors,
        )
        require(
            "Densoso/Services/HealthIntelligenceReadModel.swift",
            (
                "struct HealthIntelligenceReadModel",
                "static let workoutFetchBatchSize = 64",
                "static let weightFetchBatchSize = 64",
                "DailyMetricsReadModelMapper.make(metric)",
                "metricReadResult?.proteinG.value",
                "descriptor.fetchLimit = Self.workoutFetchBatchSize",
                "descriptor.fetchLimit = Self.weightFetchBatchSize",
                "static let schedulePlanFetchBatchSize = 64",
                "ordinaryEventDescriptor.fetchLimit = 1",
                "planDescriptor.fetchLimit = Self.schedulePlanFetchBatchSize",
                "planDescriptor.fetchOffset = planOffset",
                "event.notes?.contains(workoutPlanPrefix) != true",
                "event.notes?.contains(trainingPlanPrefix) != true",
                "event.notes?.contains(workoutPlanPrefix) == true",
                "event.notes?.contains(trainingPlanPrefix) == true",
                "$0.dayKey >= startKey && $0.dayKey <= endKey",
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
                "try await healthProjectionActor.healthNarrativeContext()",
                "DailyLoopSnapshotService(",
                "healthProjectionActor: healthProjectionActor",
            ),
            errors,
        )
        require(
            "Densoso/Agent/AgentSession.swift",
            (
                "(@Sendable () async throws -> HealthNarrativeContext?)?",
                "narrativeContext = try await healthNarrativeContextProvider?()",
                "let wantsHealthNarrative = HealthContextPromptBuilder.requiresNarrative(for: promptUserText)",
                "if wantsHealthNarrative",
                "catch is CancellationError",
                "读取本机健康状态失败，请重试",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/AgentCoordinatorTests.swift",
            (
                "testHealthContextLoadsOnlyForRelevantHealthQuestions",
                "testHealthContextReadFailureDoesNotClaimDataIsMissing",
            ),
            errors,
        )
        require(
            ".github/workflows/build.yml",
            (
                "focused-pr-tests",
                "testPendingDeletedSampleIndexesFinishCleanupAcrossMutatingPages",
                "needs.final-acceptance.result == 'success'",
            ),
            errors,
        )
        require(
            "Densoso/Agent/Tools/GetTodayHealthStateTool.swift",
            (
                "@Sendable (Date) async throws -> HealthStateV2?",
                "let state = try await stateProvider(date)",
                "TodayTrainingLoadPayload(summary: state.trainingLoad)",
                "summary.readiness == .noData ? nil : summary.recentSevenDayLoad",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/GetTodayHealthStateToolTests.swift",
            (
                "testProviderReadFailurePropagatesInsteadOfReturningUnavailable",
                "testUnavailableTrainingLoadEncodesMissingRecentLoadAsNull",
            ),
            errors,
        )
        require(
            "Densoso/Agent/Tools/GetHealthHistoryTool.swift",
            (
                "@Sendable (Date, Date) async throws -> [HealthStateHistoryPoint]",
                "let points = try await historyProvider(startDay, endDay)",
                "latestSummaryByDay[pointDay]",
                "domainOrderKey",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/GetHealthHistoryToolTests.swift",
            (
                "testResponseCoalescesDuplicateLocalDaysAndDomainStatuses",
                "testResponseTieBreaksEqualTimestampPointsIndependentOfInputOrder",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/HealthProjectionActorTests.swift",
            (
                "testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites",
                "testHealthContextSummaryReadsCanonicalDailyMetricsProteinOnlyWhenUsable",
                "testLoadDaysIncludesAllWorkoutsAcrossStableFetchPages",
                "testLoadDaysIncludesAllWeightsAcrossStableFetchPages",
                "testPlannedWorkoutTomorrowPagesTerminalPlansUntilActiveTrainingPlan",
                "testActorHistoryRetainsExistingRangeValidation",
                "testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents",
                "testConfirmedPlanEntriesPageHistoricalPlansAndDailySnapshotRetainsOnlyCurrentSessions",
            ),
            errors,
        )
        require(
            "Densoso/Application/DailyLoop/DailyBriefRefreshPolicy.swift",
            (
                "static func shouldRefreshAfterActivation(",
                "initialRefreshCompleted: Bool",
                "lastSuccessfulRefreshDay: Date?",
                "calendar.isDate(cachedBriefDayStart, inSameDayAs: date)",
                "calendar.isDate(lastSuccessfulRefreshDay, inSameDayAs: date)",
            ),
            errors,
        )
        require(
            "Densoso/App/DensosoApp.swift",
            (
                "hasCompletedInitialDailyBriefRefresh = true",
                "await refreshStaleDailyBriefAfterActivation()",
                "lastSuccessfulRefreshDay: lastSuccessfulHealthRefreshDay",
                "lastSuccessfulHealthRefreshDay = Calendar.autoupdatingCurrent.startOfDay(for: now)",
                "dependencies.watchConnectivityCoordinator.refreshApplicationContext()",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/DailyBriefRefreshPolicyTests.swift",
            ("testActivationRefreshWaitsForInitialRefreshAndOnlyRefreshesStaleLocalDay",),
            errors,
        )
        require(
            "Densoso/Services/HealthProjectionActor.swift",
            (
                "$0.notes?.contains(workoutPlanPrefix) == true",
                "$0.notes?.contains(trainingPlanPrefix) == true",
                "FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/HealthNarrativePolicyTests.swift",
            (
                "testStructuredNarrativeAcceptsOnlyKnownEvidenceKeysAndNarrativeText",
                "testNarrativeRejectsNumericMetricClaimsUnknownKeysAndExtraFields",
                "testPromptUsesStructuredContractOnlyForPersonalHealthQuestions",
                "testRecoveryWordAloneDoesNotAttachHealthSummaryToCloudPrompt",
                "testStateWithoutAggregateSummaryDoesNotProduceHealthConclusion",
            ),
            errors,
        )
        require(
            "DensosoTests/HealthRepositoryTests.swift",
            (
                "testInsertAndDeleteReprojectsTheSameDay",
                "testConfirmedFoodHistoryRepositoryPagesMealsAndDeduplicatesFoodIDs",
                "testProjectionUsesEffectiveProfileAndHistoricalWeightWithoutBorrowingFutureData",
                "testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion",
                "testPendingDeletedSampleIndexesFinishCleanupAcrossMutatingPages",
                "testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches",
                "testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable",
                "testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown",
                "testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays",
                "testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner",
            ),
            errors,
        )
        require(
            "DensosoTests/ConfirmationCoordinatorTests.swift",
            (
                "testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision",
                "testHistoricalConfirmationKeepsPendingMetricsWhenProfileAndWeightAreMissing",
            ),
            errors,
        )
        require(
            "DensosoTests/HealthKitSyncCoordinatorTests.swift",
            (
                "testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",
                "testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder",
                "testOneFailedStreamDoesNotBlockOtherHealthMetrics",
            ),
            errors,
        )
        require(
            "DensosoTests/HealthSyncOutboxWorkerTests.swift",
            (
                "testRetryReusesStableSyncIdentifierAndVersion",
                "testInterruptedSendingEntryIsRecoveredAndRetried",
                "testInterruptedOutboxRecoveryAndProcessingPagePastBoundedBatch",
                "diagnosticSafeDetail",
            ),
            errors,
        )
        require(
            "DensosoTests/BriefNotificationSchedulerTests.swift",
            ("testNotificationErrorsExposeSharedSafeDescriptors",),
            errors,
        )
        health_sync_outbox = require(
            "Densoso/Services/HealthSyncOutboxWorker.swift",
            ("diagnosticSafeDetail",),
            errors,
        )
        if "String(describing: error)" in health_sync_outbox:
            errors.append("HealthSyncOutboxWorker must not persist raw error descriptions")
        persistence_bootstrap = require(
            "Densoso/Infrastructure/Persistence/PersistenceBootstrap.swift",
            ("diagnosticSafeDetail(for: error)", "SharedErrorDescriptor.mapped(from: error"),
            errors,
        )
        if "localizedDescription" in persistence_bootstrap:
            errors.append("PersistenceBootstrap diagnostics must not expose raw localized descriptions")
        require(
            "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
            (
                "struct HealthSyncFailure: Equatable, Sendable",
                "HealthKitSyncError stream=\\(stream.rawValue)",
                "descriptor.diagnosticSafeDetail",
                "requestID=\\(requestID.uuidString.lowercased())",
                "fallback: .healthKitUnavailableFallback",
            ),
            errors,
        )
        require(
            "Densoso/Services/DailyMetricsProjector.swift",
            (
                "$0.dayKey == targetDayKey",
                "descriptor.fetchLimit = 1",
                "DailyMetricsProjectionFingerprint.context(",
                "CaloricEngine.projectionFingerprint(",
                "DailyMetricsProjectionFingerprint.isCurrent(",
            ),
            errors,
        )
        require(
            "Densoso/Services/EffectiveProfileRevisionReader.swift",
            (
                "$0.profileKey == profileKey && $0.effectiveFrom <= date",
                "descriptor.fetchLimit = 1",
            ),
            errors,
        )
        require(
            "Densoso/Services/LocalWeightObservationReader.swift",
            (
                "$0.measuredAt <= date && $0.confidence >= minimumConfidence",
                "descriptor.fetchLimit = batchSize",
            ),
            errors,
        )
        require(
            "Densoso/Services/DailyMetricsProjector.swift",
            (
                "static func hasValidHistoricalRecomputeInputs(on date: Date, in modelContext: ModelContext) throws -> Bool",
                "static func reprojectHistoricalIfInputsAvailable(on date: Date, in modelContext: ModelContext) throws -> Bool",
                "HistoricalMetricsEligibilityPolicy.hasValidInputs(",
                "existing.requiresRecompute",
                "day < calendar.startOfDay(for: Date())",
            ),
            errors,
        )
        require(
            "Densoso/Services/HistoricalMetricsEligibilityPolicy.swift",
            (
                "enum HistoricalMetricsEligibilityPolicy",
                "static func hasValidInputs(",
                "profile.dateOfBirth.timeIntervalSince1970.isFinite",
                "profile.age(in: calendar)",
                "weight.measuredAt <= day",
                "weight.kilograms.isFinite, weight.kilograms > 0",
            ),
            errors,
        )
        require(
            "Densoso/Application/DailyLoop/HistoricalMetricsRecomputeService.swift",
            (
                "final class HistoricalMetricsRecomputeService: HistoricalMetricsRecomputing",
                "static let lookbackDayCount = 90",
                "static let maximumBatchSize = 10",
                "descriptor.fetchLimit = Self.lookbackDayCount",
                "DailyMetricsProjector.hasValidHistoricalRecomputeInputs(on: day, in: queryContext)",
                "DailyMetricsProjector.reprojectHistoricalIfInputsAvailable(on: day, in: queryContext)",
                "try queryContext.save()",
                "await Task.yield()",
                "shouldStop()",
            ),
            errors,
        )
        require(
            "Densoso/Infrastructure/Persistence/SwiftDataConfirmationRepository.swift",
            (
                "private func reprojectDaily(on date: Date) throws",
                "existingMetrics.requiresRecompute",
                "day < calendar.startOfDay(for: Date())",
                "HistoricalMetricsEligibilityPolicy.hasValidInputs(",
                "DailyMetricsProjectionFingerprint.context(",
                "CaloricEngine.projectionFingerprint(",
                "DailyMetricsProjectionFingerprint.isCurrent(",
                "fingerprintContext: fingerprintContext",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/HistoricalMetricsRecomputeServiceTests.swift",
            (
                "testRecomputesOnlyExistingEligiblePendingMetricsWithinBatch",
                "testMissingDOBDoesNotLetObservedEnergyClearRecomputeFlag",
                "testOrdinaryHistoricalReprojectKeepsPendingFlagWhenDOBMissingWithObservedEnergy",
                "testCurrentDayReprojectRetainsObservedEnergyBehaviorWithoutProfileOrWeight",
                "testMissingWeightDoesNotLetObservedEnergyClearRecomputeFlag",
                "testCancellationStopsAfterSavedRowAndReportsRetryableWork",
                "DensosoSchemaV9.self",
                "XCTAssertTrue(metric.requiresRecompute)",
            ),
            errors,
        )
        require(
            "Densoso/Infrastructure/Persistence/SwiftDataConfirmedFoodHistoryRepository.swift",
            (
                "enum ConfirmedFoodHistoryReadLimits",
                "mealPageSize = 128",
                "descriptor.fetchLimit = ConfirmedFoodHistoryReadLimits.mealPageSize",
                "cursorSourceActionKey",
                "sourceActionKey > cursorSourceActionKey",
            ),
            errors,
        )
        require(
            "Densoso/Services/HealthIntelligenceReadModel.swift",
            (
                "healthKitSampleSummary",
                "availableAggregate",
                "healthReadStates?[HealthMetricID.sleepAnalysis.rawValue]",
            ),
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
                "Vision capability is scoped to the exact `deepseek-flash` model and the official",
                "https://api-docs.deepseek.com/guides/vision/",
                "https://api-docs.deepseek.com/guides/responses_api/",
                "Image parts are allowed only in user messages",
                "Production launch does not seed a profile",
                "Qwen open-photo quality remains closed by",
                "Performance points of interest mark `App.LaunchStart`",
                "App.LaunchStart",
                "Today.InitialContentRendered",
                "Today.InitialDataReady",
                "Health.StateRefresh",
                "Meal.DeterministicEstimate",
                "Meal.DeterministicToolDraft",
                "Speech.CaptureToFirstTranscript",
                "Provider.DeepSeekFirstTextDelta",
                "Agent.TranscriptToFirstToken",
                "Agent.TranscriptToActionDraft",
                "neither the evidence message nor its OCR text is persisted",
                "ephemeral provider message for the current round",
                "require the regular health-text consent",
                "Confirmation remains required",
                "evidence-only input must be rescanned under",
                "supplemental text in the same user turn",
                "same AgentSession",
                "textAndImage",
                "The envelope stores no image bytes",
                "a text-only or Qwen provider is rejected without fallback",
                "DiagnosticsExportPrivacyTests.testProviderErrorsExportOnlyAllowlistedCodes",
                "Agent, Narrative, Meal, and Vision prompt builders expose centralized version",
                "New conversations persist `toolSchemaVersion=2`",
                "migrated from V1–V6 are lazily marked as schema v1",
                "AgentRequestResumeTests.testLegacyV1ConversationRestoresWithCurrentToolsAndAdvancesOnNewTurn",
                "AgentCoordinatorTests.testTypedEventStreamPreservesOrderAndRealCounts",
                "DensosoMigrationTests.testV6ToV7PreservesLegacyConversationAndRestoresToolSchemaV1",
                "DensosoMigrationTests.testV7ToV9PreservesHealthKitSampleIndexState",
                "DensosoMigrationTests.testV8MigrationMarksPriorRoundRequestCostUnavailableWithoutProviderIdentity",
                "AgentRequestResumeTests.testPerRequestCostReservationPersistsAndCannotResetOnResume",
                "AgentRequestResumeTests.testLegacyInterruptedRequestWithoutProviderIdentityFailsClosedBeforeCall",
                "ProviderUsageLedgerTests.testPreflightCostUsesInputUpperBoundMaximumOutputAndRetryAttempts",
                "AgentCoordinatorTests.testUnpricedProviderRequestCompletesWithUnavailableCostAccounting",
                "AgentCoordinatorTests.testCostCapIsReservedBeforeProviderOrToolInvocation",
                "ProviderUsageLedgerTests.testUsageIdentityImageCountAndLatencyAreRetainedInLedgerSummary",
                "ProviderUsageLedgerTests.testUsageWithMismatchedRequestIdentityIsRejectedBeforePersistence",
                "ProviderUsageLedgerTests.testLegacyUsagePayloadDecodesWithUnknownImageAndLatencyMetadata",
                "AgentProviderContextPolicyTests.testProviderHistoryKeepsRecentWholeTurnsAndTheCurrentTurn",
                "AgentProviderContextPolicyTests.testCurrentTurnOverBudgetFailsBeforeProviderInvocation",
                "DensosoMigrationTests.testV1DiskFixtureMigratesToCurrentSchemaWithoutRecalculation",
                "DensosoMigrationTests.testV2DiskFixtureMigratesToCurrentSchemaAndPreservesCursorAndOutbox",
                "DensosoMigrationTests.testV3MigrationToCurrentSchemaCreatesTimeAwareProfileAndWeightRecords",
                "PromptVersioningTests.testPromptAndToolSchemaVersionsMatchMainPR111And112",
                "DensosoMigrationTests.testPersistenceBootstrapErrorsUseSafeReadOnlyDescriptor",
                "ConfirmationCoordinatorTests.testConfirmedActionTraceabilityLinksReceiptLocalRecordAndOutbox",
                "MealRecordAuditPresentationTests.testMealRecordPresentationShowsSanitizedSourcesAndAlgorithmVersion",
                "AgentUIStateMachineTests.testAgentEventsMoveThroughThinkingToolDraftConfirmationCommitAndFailureStates",
                "AgentUIStateMachineTests.testVoiceUIStateMapsExistingSpeechCaptureStatesAndFailureKinds",
                "MealImageCaptureStateMachineTests.testOpenPhotoRequiresConsentBeforeUploadAndMovesThroughVisionResolution",
                "MealImageCaptureStateMachineTests.testLocalResolutionAndCancellationNeverBecomeUploadable",
                "IntelligenceRoutingPolicyTests.testDefaultModeIsCloudDeepSeek",
                "IntelligenceRoutingPolicyTests.testCloudRequiresExplicitCloudMode",
                "MealCaptureApplicationServiceTests.testLocalOnlyBarcodeScanNeverCallsPackagedFoodProvider",
                "SpeechCaptureStateMachineTests.testLocalOnlyModeNeverUsesQwenFallbackEvenWhenFallbackAndConsentAreEnabled",
                "sanitized request remains local until its explicit DeepSeek",
                "Image state events carry no image or OCR content",
                "Cloud DeepSeek is the default mode",
                "without silent fallback to another provider",
                "Local Only keeps model",
            ),
            errors,
        )
        chat = require(
            "Densoso/Views/ChatScreen.swift",
            (
                "inputText = speech.transcribedText",
                "dependencies.agentSession.sendEvents(",
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
                "prepareCapture(data, preparationID: preparationID)",
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
        require(
            "Densoso/Application/Meal/MealCaptureApplicationService.swift",
            (
                "enum MealCaptureApplicationError: Equatable, SharedErrorDescribing",
                "var sharedErrorDescriptor: SharedErrorDescriptor",
                "var errorDescription: String? { sharedErrorDescriptor.userMessage }",
            ),
            errors,
        )
        require(
            "Densoso/Views/SettingsScreen.swift",
            (
                "private enum GoalInputError: SharedErrorDescribing",
                "var sharedErrorDescriptor: SharedErrorDescriptor",
            ),
            errors,
        )
        require(
            "Densoso/Views/MealCaptureSheet.swift",
            (
                "private enum CameraImagePickerError: SharedErrorDescribing",
                "var sharedErrorDescriptor: SharedErrorDescriptor",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/MealCaptureApplicationServiceTests.swift",
            ("testMealCaptureErrorsExposeSharedSafeDescriptors",),
            errors,
        )
        for error_surface in (
            "Densoso/Views/ChatScreen.swift",
            "Densoso/Views/DashboardScreen.swift",
            "Densoso/Views/OnboardingView.swift",
            "Densoso/Views/MealCaptureSheet.swift",
            "Densoso/Views/SettingsScreen.swift",
            "Densoso/Views/HistoryScreen.swift",
        ):
            error_surface_source = require(error_surface, ("SharedErrorDescriptor.mapped(",), errors)
            if "error.localizedDescription" in error_surface_source:
                errors.append(f"{error_surface} must not display raw error.localizedDescription")
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
                "withoutSensitiveTransientContent",
                "func currentMealImageEvidence()",
                "func currentMealHasImage() -> Bool",
                "transientMealHasImage = multimodalRequest.image != nil",
                "transientMealImageEvidence = multimodalRequest.mealEvidence",
                "providerMessagesIncludingTransientMealEvidence(",
                "transientMealEvidenceMessage",
                "messagesWithoutLocalMetadata",
                "inputEnvelope: message.inputEnvelope",
                "multimodalRequest.inputEnvelope.isWellFormed",
                "case invalidInputEnvelope",
            ),
            errors,
        )
        session_stream_contract = require(
            "Densoso/Agent/AgentSession.swift",
            (
                "func sendEvents(\n        multimodalRequest: MultimodalModelRequest,\n        requestID: UUID? = nil",
                "func sendEvents(\n        userText: String,\n        inputEnvelope: InputEnvelope",
                "emit(.committing(actionID: id))",
            ),
            errors,
        )
        image_consent_offset = session.find("dataClass: .mealImage")
        image_upload_offset = session.find("emit(.imageUploading)")
        if image_consent_offset < 0 or image_upload_offset < image_consent_offset:
            errors.append("AgentSession must verify meal-image consent before the image-upload state event")
        chat = require(
            "Densoso/Views/ChatScreen.swift",
            (
                "@State private var agentUIState: AgentUIState = .idle",
                "@State private var voiceUIState: VoiceCaptureUIState = .idle",
                "dependencies.agentSession.sendEvents(",
                "transitionAgentUI(using: event)",
                "AgentUIStateMachine.voiceState(",
                "agentUIState.isBusy",
                "agentUIState.canCancel",
            ),
            errors,
        )
        if "@State private var isProcessing = false" in chat:
            errors.append("ChatScreen must use explicit AgentUIState instead of a single processing boolean")
        require(
            "Densoso/Application/Agent/AgentUIStateMachine.swift",
            (
                "enum AgentUIState: Equatable",
                "case listening",
                "case transcribing",
                "case thinking",
                "case toolExecuting(name: String)",
                "case draftReady",
                "case awaitingConfirmation",
                "case committing",
                "case completed",
                "case failed",
                "event: AgentEvent",
                "from state: SpeechCaptureState",
                "case .pendingAction(_):\n            .draftReady",
                "case .awaitingConfirmation:\n            .awaitingConfirmation",
                "case .committing(_):\n            .committing",
                "hasDraftInCurrentTurn: Bool = false",
                "current == .draftReady || hasDraftInCurrentTurn ? .awaitingConfirmation : .idle",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/AgentUIStateMachineTests.swift",
            (
                "testAgentEventsMoveThroughThinkingToolDraftConfirmationCommitAndFailureStates",
                "testVoiceUIStateMapsExistingSpeechCaptureStatesAndFailureKinds",
                "hasDraftInCurrentTurn: true",
            ),
            errors,
        )
        require(
            "Densoso/Application/Meal/MealImageCaptureState.swift",
            (
                "case selected",
                "case sanitizing",
                "case localScanning",
                "case localResolved",
                "case deepseekRequired",
                "case consent",
                "case uploading",
                "case vision",
                "case resolved",
                "case cancelled",
                "func canSend(preparedRequestExists: Bool, consentGranted: Bool) -> Bool",
                "case .uploadStarted where current.canSend(",
            ),
            errors,
        )
        meal_capture_sheet = require(
            "Densoso/Views/MealCaptureSheet.swift",
            (
                "onImageStateChange: (MealImageCaptureState) -> Void",
                "guard canSendPhotoToAgent else { return }",
                "onSendToAgent(preparedRequest)",
                "imageCaptureState.canSend(",
                "granted: true",
                "imageCaptureState == .uploading || imageCaptureState == .vision",
                "activePreparationID == preparationID",
                "policyVersion: \"deepseek-sanitized-meal-image-v1\"",
                "不会自动切换提供方或上传照片",
                "授权会保存到设置中，可随时撤回",
            ),
            errors,
        )
        consent_guard_offset = meal_capture_sheet.find("guard canSendPhotoToAgent else { return }")
        upload_call_offset = meal_capture_sheet.find("onSendToAgent(preparedRequest)")
        if consent_guard_offset < 0 or upload_call_offset < consent_guard_offset:
            errors.append("MealCaptureSheet must check explicit consent before handing an image to AgentSession")
        require(
            "Densoso/Application/Meal/MealCaptureApplicationService.swift",
            (
                "onImageStateChange: (@MainActor (MealImageCaptureState) -> Void)? = nil",
                "onImageStateChange?(.sanitizing)",
                "onImageStateChange?(.localScanning)",
                "try Task.checkCancellation()",
                "onImageStateChange?(.deepseekRequired)",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/MealImageCaptureStateMachineTests.swift",
            (
                "testOpenPhotoRequiresConsentBeforeUploadAndMovesThroughVisionResolution",
                "testLocalResolutionAndCancellationNeverBecomeUploadable",
                "canSend(preparedRequestExists: true, consentGranted: false)",
            ),
            errors,
        )
        require(
            "Densoso/Services/IntelligenceRouting.swift",
            (
                "static let defaultMode = IntelligenceMode.cloudDeepSeek",
                "case .cloudDeepSeek:\n            return DeepSeekProvider(",
                "case .cloudQwen:\n            return QwenProvider(",
                "case .localOnly:\n            throw ProviderError.unsupportedCapability(.text)",
            ),
            errors,
        )
        require(
            "Densoso/App/AppLaunchConfiguration.swift",
            (
                'usesSeededProfile: isUITesting && arguments.contains("-ui-testing-seeded")',
                'let isUITesting = arguments.contains("-ui-testing")',
            ),
            errors,
        )
        require(
            "Densoso/App/DensosoApp.swift",
            (
                "if launchConfiguration.isUITesting",
                "guard launchConfiguration.usesSeededProfile else",
            ),
            errors,
        )
        require(
            "Densoso/Views/OnboardingView.swift",
            (
                "@State private var dateOfBirth: Date?",
                "@State private var hasEditedDateOfBirth = false",
                "dateOfBirth = dateOfBirthDraft",
                ".disabled(!hasEditedDateOfBirth)",
                "let birthDate = dateOfBirth",
            ),
            errors,
        )
        require(
            "Densoso/Services/PerformanceSignposts.swift",
            (
                "OSSignposter",
                "func measure<T>(",
                "func measureAsync<T>(",
                "func event(",
            ),
            errors,
        )
        require(
            "Densoso/Views/ChatScreen.swift",
            (
                "Today.InitialContentRendered",
                "Today.InitialDataReady",
                "Agent.TranscriptToFirstToken",
                "Agent.TranscriptToActionDraft",
            ),
            errors,
        )
        require(
            "Densoso/Services/HealthIntelligenceService.swift",
            ("Health.StateRefresh",),
            errors,
        )
        require(
            "Densoso/Services/SpeechService.swift",
            ("Speech.CaptureToFirstTranscript", "recordFirstTranscriptLatencyIfNeeded"),
            errors,
        )
        require(
            "Densoso/Services/FoodDatabase.swift",
            ("catalogEntriesCache", "catalogCacheLock.lock()"),
            errors,
        )
        require(
            "DensosoTests/FoodDatabaseTests.swift",
            ("testCatalogEntriesRemainStableAcrossRepeatedReads",),
            errors,
        )
        require(
            "DensosoTests/AppLaunchConfigurationTests.swift",
            (
                "testSeededProfileRequiresUITestMode",
                "testUITestArgumentsEnableDeterministicSeed",
            ),
            errors,
        )
        require(
            "Densoso/Infrastructure/LLM/ProviderConfiguration.swift",
            (
                'static let deepSeekFlashModel = "deepseek-flash"',
                'static let deepSeekResponsesEndpoint = URL(string: "https://api.deepseek.com/responses")!',
                "static func deepSeekCapabilities(for model: String, endpoint: URL)",
                "endpoint == deepSeekResponsesEndpoint",
            ),
            errors,
        )
        require(
            "Densoso/Infrastructure/LLM/DeepSeekProvider.swift",
            (
                "model: String = ProviderCapabilityCatalog.deepSeekFlashModel",
                "endpoint: URL = ProviderCapabilityCatalog.deepSeekResponsesEndpoint",
                "capabilities: ProviderCapabilityCatalog.deepSeekCapabilities(for: model, endpoint: endpoint)",
                "input_image",
                "imageMessages.allSatisfy({ $0.role == .user })",
                "Provider.DeepSeekFirstTextDelta",
            ),
            errors,
        )
        require(
            "Densoso/App/Dependencies.swift",
            (
                "let mode = intelligencePreferences.mode",
                "let localOnly = mode == .localOnly",
                "let explicitlySelectedQwen = mode == .cloudQwen",
                "packagedFoodProvider: localOnly ? nil : packagedFoodProvider",
                "allowsRemotePackagedFoodLookup: !localOnly",
                "visionProvider: visionProvider",
                "allowsQwenMealVision: explicitlySelectedQwen",
                "cloudFallbackModeIsAllowed: { intelligencePreferences.mode != .localOnly }",
            ),
            errors,
        )
        require(
            "Densoso/Application/Meal/MealCaptureApplicationService.swift",
            (
                "allowsQwenMealVision: Bool = false",
                "allowsQwenMealVision,",
                "Optional Qwen review path",
                "qualityGate: MealVisionQualityGate = .unavailable",
                'PerformanceSignposts.measure("Meal.DeterministicEstimate")',
            ),
            errors,
        )
        require(
            "Densoso/Agent/Tools/LogMealTool.swift",
            ('PerformanceSignposts.measure("Meal.DeterministicEstimate")',),
            errors,
        )
        require(
            "Densoso/Agent/AgentSession.swift",
            ('PerformanceSignposts.measureAsync("Meal.DeterministicToolDraft")',),
            errors,
        )
        require(
            "Densoso/Views/OnboardingView.swift",
            ("@State private var intelligenceMode: IntelligenceMode = .cloudDeepSeek",),
            errors,
        )
        require(
            "Densoso/Services/SpeechService.swift",
            (
                "cloudFallbackModeIsAllowed: @escaping @MainActor () -> Bool = { true }",
                "guard cloudFallbackModeIsAllowed(),",
            ),
            errors,
        )
        require(
            "DensosoTests/IntelligenceRoutingPolicyTests.swift",
            (
                "testDefaultModeIsCloudDeepSeek",
                "testCloudRequiresExplicitCloudMode",
                "testDeepSeekVisionCapabilityIsScopedToDocumentedModelAndEndpoint",
            ),
            errors,
        )
        require(
            "Densoso/Views/MealCaptureSheet.swift",
            (
                "开放照片默认通过 DeepSeek Agent 处理",
                "当前 Qwen 模式暂未启用开放照片输入",
                "当前为 Local Only，照片仍留在本机",
                "不会自动切换提供方或上传照片",
            ),
            errors,
        )
        require(
            "Densoso/Views/HistoryScreen.swift",
            ("MealRecordAuditPresentation.summary(",),
            errors,
        )
        require(
            "Densoso/Views/MealRecordAuditPresentation.swift",
            (
                "static func summary(evidenceData: Data?, algorithmVersion: String)",
                "sourceID.hasPrefix(\"agent-image:\")",
                "return \"来源：\\(source) · 算法：\\(displayVersion)\"",
            ),
            errors,
        )
        require(
            "DensosoTests/MealRecordAuditPresentationTests.swift",
            (
                "testMealRecordPresentationShowsSanitizedSourcesAndAlgorithmVersion",
                "PRIVATE OCR CONTENT MUST NOT BE SHOWN",
                "XCTAssertFalse(summary.contains(\"PRIVATE\"))",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/MealCaptureApplicationServiceTests.swift",
            ("testLocalOnlyBarcodeScanNeverCallsPackagedFoodProvider", "allowsRemotePackagedFoodLookup: false"),
            errors,
        )
        require(
            "DensosoTests/Application/SpeechCaptureStateMachineTests.swift",
            ("testLocalOnlyModeNeverUsesQwenFallbackEvenWhenFallbackAndConsentAreEnabled",),
            errors,
        )
        require(
            "Densoso/Application/Agent/AgentEvents.swift",
            (
                "case failed(SharedErrorDescriptor)",
                "case awaitingConfirmation",
                "case committing(actionID: UUID)",
                "case imageUploading",
                "case imageVision",
                "case imageResolved",
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
                "public let voiceSource: VoiceCommandEnvelope.Source?",
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
                "voice.asInputEnvelope().voiceSource, .iPhoneSpeechAnalyzer",
                "typed.asInputEnvelope(imageAttachments: [image]).voiceSource",
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
                "context.currentMealHasImage()",
                "ingredient.quantityEvidence.kind == .photoEstimate",
                "currentMealClarificationWasAnswered()",
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
                "testTypedEventStreamPreservesOrderAndRealCounts",
                "testProviderReasoningContinuesInMemoryButIsNeverPersisted",
                "testCloudProviderRequiresExplicitConsent",
                "testNinthToolCallStopsRequest",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/AgentRequestResumeTests.swift",
            (
                "testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage",
                "testLegacyV1ConversationRestoresWithCurrentToolsAndAdvancesOnNewTurn",
                "testPerRequestCostReservationPersistsAndCannotResetOnResume",
            ),
            errors,
        )
        require(
            "DensosoTests/DensosoMigrationTests.swift",
            (
                "testV6ToV7PreservesLegacyConversationAndRestoresToolSchemaV1",
                "testV7ToV9PreservesHealthKitSampleIndexState",
                "testV8MigrationMarksPriorRoundRequestCostUnavailableWithoutProviderIdentity",
                "testPersistenceBootstrapErrorsUseSafeReadOnlyDescriptor",
            ),
            errors,
        )
        require(
            "DensosoTests/Application/PromptVersioningTests.swift",
            ("testPromptAndToolSchemaVersionsMatchMainPR111And112",),
            errors,
        )
        require(
            "Densoso/Application/Agent/PromptVersions.swift",
            (
                'static let current = "agent-v2"',
                'static let current = "health-narrative-v1"',
                'static let current = "meal-v2"',
                'static let current = "meal-vision-v2"',
            ),
            errors,
        )
        require(
            "Densoso/Application/Agent/ToolSchemaVersion.swift",
            (
                "static let legacy = 1",
                "static let current = 2",
                "static func supportsRestore(_ version: Int) -> Bool",
            ),
            errors,
        )
        require(
            "Densoso/Persistence/Schemas/DensosoSchemaV7.swift",
            (
                "enum DensosoSchemaV7: VersionedSchema",
                "DensosoSchemaV6.models + [ConversationToolSchemaVersionRecord.self]",
                "var toolSchemaVersion: Int",
            ),
            errors,
        )
        require(
            "Densoso/Persistence/Schemas/DensosoSchemaV8.swift",
            (
                "enum DensosoSchemaV8: VersionedSchema",
                "DensosoSchemaV5.models + [",
                "@Attribute(originalName: \"isDeleted\") var isTombstoned: Bool",
            ),
            errors,
        )
        require(
            "Densoso/Persistence/Schemas/DensosoSchemaV9.swift",
            (
                "enum DensosoSchemaV9: VersionedSchema",
                "DensosoSchemaV8.models.filter",
                "ObjectIdentifier($0) != ObjectIdentifier(DensosoSchemaV4.ProviderUsageRecord.self)",
                "ProviderUsageRecord.self",
                "var imageCount: Int = 0",
                "var maximumCostMicros: Int64",
                "var reservedCostMicros: Int64",
                "var lastReservedProviderRound: Int",
            ),
            errors,
        )
        require(
            "Densoso/Persistence/DensosoMigrationPlan.swift",
            (
                "DensosoSchemaV7.self",
                ".lightweight(fromVersion: DensosoSchemaV6.self, toVersion: DensosoSchemaV7.self)",
                "DensosoSchemaV8.self",
                ".lightweight(fromVersion: DensosoSchemaV7.self, toVersion: DensosoSchemaV8.self)",
                "DensosoSchemaV9.self",
                ".lightweight(fromVersion: DensosoSchemaV8.self, toVersion: DensosoSchemaV9.self)",
            ),
            errors,
        )
        require(
            "Densoso/Infrastructure/Persistence/SwiftDataAgentRepository.swift",
            (
                "func toolSchemaVersion(conversationID: UUID) throws -> Int",
                "ToolSchemaVersion.legacy",
                "ToolSchemaVersion.current",
                "version.toolSchemaVersion = ToolSchemaVersion.current",
            ),
            errors,
        )
        require(
            "DensosoTests/Infrastructure/LLM/DeepSeekProviderContractTests.swift",
            (
                "testResponsesAPIRequestAndStreamingToolContract",
                "testImageStructuredOutputAndStatelessToolHistoryEncoding",
                "testImageMustBeInUserMessageAndFailsBeforeNetwork",
            ),
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
            "DensosoTests/Privacy/DiagnosticsExportPrivacyTests.swift",
            ("testProviderErrorsExportOnlyAllowlistedCodes",),
            errors,
        )
        require(
            "Densoso/Infrastructure/LLM/ProviderLogRedactor.swift",
            (
                "SharedErrorCode(rawValue: candidate)",
                "SharedErrorCode.providerUnavailable.rawValue",
                "error.sharedErrorDescriptor.code.rawValue",
            ),
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
                "testOptionalQwenOpenPhotoRequiresSeparateQwenConsent",
                "testDeepSeekPhotoModeNeverFallsThroughToOptionalQwenVision",
                "testDefaultClosedQualityGateRequiresManualFallbackWithoutStaging",
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
                "includingSupplementalText(supplementalText, source: .qwenASR)",
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
                "component-wise observed basal/active expenditure",
                "explicit-profile fallback",
                "historical effective profile/weight selection",
                "shared metric availability and coverage",
                "likely-range meal estimates",
            ),
            errors,
        )
        require(
            "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/EnergyAccountingTests.swift",
            (
                "testObservedExpenditureUsesBasalPlusActiveExactlyOnce",
                "testMissingHealthKitComponentUsesExplicitProfileEstimate",
                "testObservedActiveEnergyIsAddedToEstimatedBasalOnlyOnce",
                "testObservedBasalWithoutEstimateableActiveRemainsPartial",
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
            (
                "testExplicitOilIsAddedOnceWithoutCookingMultiplier",
                "testInferredOilProducesAnHonestInterval",
                "testDeterministicMealEstimateReportsP50P95AgainstLatencyTarget",
            ),
            errors,
        )
        return "energy-accounting"

    require(
        "docs/gates/gate-14-watch-daily-loop.md",
        (
            "Gate 14",
            "daily snapshot summaries",
            "local day key/time zone, projection version, stable source fingerprint, per-metric availability and freshness state",
            "stale or missing brief offers a refresh",
            "offline replay deduplication",
            "arrival ordering",
            "Sequenced commands wait while their predecessor is missing",
            "Rejected or conflicting predecessors terminally",
            "Transcripts remain pending until the user sends",
            "terminal causal sequence watermark",
            "Missing or pending sequences stop the watermark",
            "in-memory sequence cache from paged inbox records",
            "App restarts rebuild the cache from durable records",
            "Local confirmation and WorkoutKit scheduling remain separate states",
            "its local intent remains retryable",
            "WorkoutPlanCompilerTests.testWorkoutKitErrorsUseSharedCodesAndSafeMessages",
            "TrainingPlanDraftTests",
            "goal, location, intensity, and reason details",
            "After local midnight, an older snapshot is",
            "Pending actions remain",
            "manual Gate 15",
            "Simulator evidence does not prove Watch pairing",
        ),
        errors,
    )
    workout_plan_screen = require(
        "Densoso/Views/WorkoutPlanScreen.swift",
        (
            "private func refreshConfirmedPlans()",
            "private func loadMoreConfirmedPlans()",
            "confirmedPlansPage(offset: 0)",
            "confirmedTrainingPlansPage(offset: 0)",
            "confirmedPlansNextOffset",
            "confirmedTrainingPlansNextOffset",
            "isLoadingMoreConfirmedPlans",
            "shouldRetryLoadingMoreConfirmedPlans",
            "private var confirmedPlansReadError: String?",
            "if let confirmedPlansReadError",
            'Button("重试")',
            "confirmedPlans = []",
            "confirmedTrainingPlans = []",
            "读取已确认的计划失败：",
            "confirmedPlansReadError = nil",
            'isLoadingMoreConfirmedPlans ? "正在加载…" : "加载更多已确认计划"',
            "uniqueWorkoutPlans(confirmedPlans + plans.entries)",
            "uniqueTrainingPlans(confirmedTrainingPlans + trainingPlans.entries)",
        ),
        errors,
    )
    refresh_method = workout_plan_screen.split("private func refreshConfirmedPlans()", 1)[-1]
    refresh_method = refresh_method.split("\n    private func ", 1)[0]
    if "confirmedPlansPage(offset: 0)" not in refresh_method or "confirmedTrainingPlansPage(offset: 0)" not in refresh_method:
        errors.append("Refreshing confirmed workout plans must restart both bounded pages at zero")
    require(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/DailyLoopSnapshotTests.swift",
        (
            "testSnapshotRoundTripsStateGuidanceAndActionSummaries",
            "testLegacySnapshotDecodesWithUnknownProvenanceAndRefreshRequiredState",
        ),
        errors,
    )
    require(
        "Packages/DensosoDomain/Sources/DensosoDomain/DailyLoopSnapshot.swift",
        (
            "public let dayKey: String",
            "public let timezoneIdentifier: String",
            "public let sourceFingerprint: String?",
            "public let projectionVersion: String",
            "public static let legacyProjectionVersion = \"legacy-unknown\"",
            "public let coverage: DailyLoopMetricCoverage",
            "public let refreshState: DailyLoopRefreshState",
            "public let errorCode: String?",
            "case error",
            "public static func localDayKey(for date: Date, timezoneIdentifier: String)",
        ),
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
            "testCausalSequenceSurvivesAcknowledgementAndOutboxRestore",
            "testCausalDependencyPolicyWaitsAndFailsOnRejectedOrConflictingPredecessors",
            "testTerminalSequenceWatermarkAcknowledgesOnlyCoveredCausalEntries",
            "testSnapshotRequestPolicyCoalescesOnlyUntilAcknowledged",
            "testTodaySnapshotRoundTripsTomorrowGuidanceAndDecodesLegacyPayload",
            "testTodaySnapshotExpiresAtInjectedCalendarLocalMidnight",
            "XCTAssertEqual(decodedLegacyPayload.tomorrowGuidance?.reasons, [])",
            "XCTAssertEqual(snapshot.activePendingActions(asOf: afterMidnight), [activeAction])",
            'XCTAssertEqual(Set(try XCTUnwrap(encodedDomains.first).keys), ["domain", "status"])',
            "XCTAssertEqual(roundTripped.recoverySummary, recoverySummary)",
        ),
        errors,
    )
    require(
        "Packages/DensosoDomain/Sources/DensosoDomain/WatchConnectivityContracts.swift",
        (
            "public struct WatchRecoverySummary: Codable, Equatable, Sendable",
            "public struct WatchTomorrowGuidanceSummary: Codable, Equatable, Sendable",
            "public let reasons: [EvidenceReference]",
            "reasons = []",
            "decodeIfPresent([EvidenceReference].self, forKey: .reasons)",
            "try container.encode([EvidenceReference](), forKey: .reasons)",
            "public struct WatchHealthDomainStatus: Codable, Equatable, Sendable",
            "public let domains: [WatchHealthDomainStatus]",
            "public let recoverySummary: WatchRecoverySummary?",
            "public let tomorrowGuidance: WatchTomorrowGuidanceSummary?",
            "public let terminalCausalSequenceWatermark: Int?",
            "tomorrowGuidance: WatchTomorrowGuidanceSummary? = nil",
            "terminalCausalSequenceWatermark: Int? = nil",
            "recoverySummary: WatchRecoverySummary? = nil",
            "Message IDs whose receipt reached a processed/rejected terminal state.",
            "public func isCurrentLocalDay(asOf date: Date, calendar: Calendar) -> Bool",
            "public func activePendingActions(asOf date: Date) -> [WatchPendingActionSummary]",
        ),
        errors,
    )
    watch_contract = read_text("Packages/DensosoDomain/Sources/DensosoDomain/WatchConnectivityContracts.swift", errors)
    watch_snapshot_contract = watch_contract.split("public struct WatchTodaySnapshot:", 1)[-1].split("public enum WatchMessageError", 1)[0]
    for legacy_watch_field in ("energyIntakeKcal", "totalExpenditureKcal", "deficitKcal"):
        if legacy_watch_field in watch_snapshot_contract:
            errors.append(f"WatchTodaySnapshot must not expose numeric health field {legacy_watch_field}")
    if "DailyMetrics" in watch_snapshot_contract:
        errors.append("WatchTodaySnapshot must not expose DailyMetrics data")
    guidance_contract = watch_contract.split("public struct WatchTomorrowGuidanceSummary:", 1)[-1].split(
        "public struct WatchHealthDomainStatus:", 1
    )[0]
    if "container.encode(reasons" in guidance_contract:
        errors.append("Watch tomorrow guidance must not re-emit evidence reasons")
    require(
        "Packages/DensosoDomain/Sources/DensosoDomain/WatchConnectivityContracts.swift",
        (
            "private var lastCausalSequence: Int?",
            "public var latestCausalSequence: Int?",
            "public var latestPendingCausalSequence: Int?",
            "causalSequence: previousSequence + 1",
            "case .accepted, .processed, .duplicate, .rejected:",
            "pendingByID[acknowledgement.messageID]?.causalSequence == nil",
            "acknowledge(throughCausalSequence watermark: Int) -> [UUID]",
        ),
        errors,
    )
    require(
        "DensosoWatchExtension/WatchCompanionView.swift",
        (
            "currentSnapshot(asOf: date)?.tomorrowGuidance",
            "Text(guidance.conditionalNote)",
            "recommendedActionName(guidance.recommendedAction)",
            "snapshot.recoverySummary",
            'LabeledContent("恢复", value: recoveryStatusName(recovery.status))',
            "ForEach(HealthDomain.allCases, id: \\.self)",
            "domainStatusName(result.status)",
            "TimelineView(.periodic(from: .now, by: 60))",
            "snapshot.isCurrentLocalDay(asOf: date, calendar: calendar)",
            'Text("最近同步")',
            "Text(syncDateLabel(snapshot.generatedAt))",
            "formatter.calendar = calendar",
            "snapshot.activePendingActions(asOf: now)",
            "if let snapshot = currentSnapshot(asOf: date), !snapshot.workoutPlans.isEmpty",
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
            "testCausalReplayWaitsForMissingAndPendingPredecessorThenOrdersBySequence",
            "testRejectedAndConflictingPredecessorsRejectCausalSuccessors",
            "testTerminalCausalWatermarkStopsAtMissingAndPendingSequences",
            "testTerminalCausalWatermarkCacheTracksChangesAndRebuildsAfterStoreRestart",
            "testCausalTranscriptWaitsForPredecessorAndStaysPendingUntilConsumed",
            "testLegacyPendingCommandAndTranscriptBlockNewerCommandUntilCompleted",
            "testPendingCommandQueryMatchesZeroUUIDAndSkipsNilRequestIDInArrivalOrder",
            "testPendingInboxOrdersEqualOrdinalsByMessageIDAcrossReceiptPages",
            "testPendingInboxPagesMoreThan64ReceiptsInArrivalOrder",
            "ordinal: 4",
            "1...65",
            "0..<65",
            "pendingCommands.map(\\.messageID), [laterRequestID, firstRequestID]",
            "pendingCommandEnvelopes().map(\\.messageID), expectedCommandIDs",
            "00000000-0000-0000-0000-000000000000",
            "requestID: nil",
            "store.recentReceivedMessageIDs(), [firstID, zeroID]",
            "testOutOfOrderMessagesAreReturnedInDurableArrivalOrder",
            "testRecentInboxQueriesFilterStatesAndApplyLimitsInArrivalOrder",
        ),
        errors,
    )
    require(
        "Densoso/Application/Workout/TrainingPlanSchedulingService.swift",
        (
            "func upcomingConfirmedSessions(",
            "let boundedLimit = max(limit, 0)",
            "descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize",
            "dateRange.contains(session.date)",
            "entry.state != .terminal",
            "summaries.count > boundedLimit",
        ),
        errors,
    )
    require(
        "Densoso/Services/WorkoutPlanCompiler.swift",
        ("func upcomingConfirmedTrainingSessions(",),
        errors,
    )
    require(
        "DensosoTests/TrainingPlanSchedulingServiceTests.swift",
        ("testUpcomingTrainingSessionsAreBoundedAndOrderedAcrossPages",),
        errors,
    )
    inbox_store = require(
        "Densoso/Infrastructure/WatchConnectivity/WatchMessageInboxStore.swift",
        (
            "let pendingIDs = try pendingMessageIDs(in: context)",
            "private func pendingMessageIDs(in context: ModelContext) throws -> Set<UUID>",
            "pendingIDs.formUnion(receipts.compactMap { UUID(uuidString: $0.messageID) })",
            "message.conversationID == inboxID",
            "message.roleRaw == role",
            "guard let requestID = message.requestID else { return false }",
            "return pendingIDs.contains(requestID)",
            "descriptor.fetchLimit = Self.pendingReceiptFetchBatchSize",
            "$0.ordinal == $1.ordinal ? $0.id < $1.id : $0.ordinal < $1.ordinal",
            "descriptor.fetchLimit = boundedLimit",
            "SortDescriptor(\\.ordinal, order: .reverse)",
        ),
        errors,
    )
    if "message.requestID!" in inbox_store:
        errors.append("Watch inbox SwiftData predicates must not force unwrap optional request IDs")
    require(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
        (
            "calendar.isDate(brief.dayStart, inSameDayAs: today) ? brief : nil",
            "let received = try inboxStore.recentProcessedMessageIDs()",
            "upcomingConfirmedPlans(from: today, limit: Self.watchSnapshotEntryLimit)",
            "upcomingConfirmedTrainingSessions(in: today..<dayAfterTomorrow, limit: Self.watchSnapshotEntryLimit)",
            "tomorrowGuidance: todayBrief?.healthState?.tomorrowGuidance.map",
            "WatchTomorrowGuidanceSummary(",
            "recoverySummary: todayBrief?.healthState.map",
            "WatchHealthDomainStatus(domain: $0.domain, status: $0.status)",
            "private static let watchSnapshotEntryLimit = 10",
            "lhs.expiresAt < rhs.expiresAt",
            "lhs.id.uuidString < rhs.id.uuidString",
            ".prefix(Self.watchSnapshotEntryLimit)",
            "return lhs.actionID.uuidString < rhs.actionID.uuidString",
        ),
        errors,
    )
    phone_watch_coordinator = read_text(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift", errors
    )
    if "DailyMetrics" in phone_watch_coordinator:
        errors.append("Phone Watch snapshot must not query DailyMetrics")
    require(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
        (
            "inboxStore.pendingReplayEnvelopes()",
            "inboxStore.causalSequenceStates(for: [envelope])",
            "inboxStore.highestContiguousTerminalCausalSequence()",
            "terminalCausalSequenceWatermark: terminalCausalSequenceWatermark",
            "case .waitingFor(let sequence)",
            "case .rejectedBecause(let sequence)",
            "inboxStore.hasEarlierPendingCommand(before: envelope.messageID)",
            "inboxStore.nextEligibleTranscript(excluding: claimedIDs)",
            "private func setReceiptState(_ state: String, for messageID: UUID) throws",
            "func markTranscriptProcessed(_ messageID: UUID) throws",
            "try setReceiptState(WatchReceiptState.processed, for: messageID)",
        ),
        errors,
    )
    require(
        "Densoso/Infrastructure/WatchConnectivity/WatchMessageInboxStore.swift",
        (
            "func pendingReplayEnvelopes() throws -> [WatchMessageEnvelope]",
            "func nextEligibleTranscript(excluding claimedIDs: Set<UUID> = []) throws -> PendingWatchTranscript?",
            "func recentProcessedMessageIDs(limit: Int = 100) throws -> [UUID]",
            "func highestContiguousTerminalCausalSequence() throws -> Int?",
            "private var terminalCausalSequenceWatermarkCache: TerminalCausalSequenceWatermarkCache?",
            "try scanCausalSequenceReceiptCounts()",
            "recordNewPendingReceipt(sequence: sequence)",
            "recordReceiptStateChange(",
            "private func forEachInboxMessage(_ body: (MessageRecord) throws -> Void) throws",
            "let sortBy = [SortDescriptor(\\MessageRecord.ordinal), SortDescriptor(\\MessageRecord.id)]",
            "func causalSequenceStates(for envelopes: [WatchMessageEnvelope]) throws",
            "sequences.contains(sequence)",
            "duplicateSequences.insert(sequence)",
            "WatchCommandDependencyPolicy.decision(for: envelope, sequenceStates: states) == .ready",
        ),
        errors,
    )
    require(
        "DensosoWatchExtension/WatchConnectivityClient.swift",
        (
            "let predecessorSequence = outbox.latestPendingCausalSequence",
            "dependsOn: predecessorSequence",
            "snapshot.terminalCausalSequenceWatermark",
            "outbox.acknowledge(throughCausalSequence: watermark)",
        ),
        errors,
    )
    require(
        "Densoso/Services/HealthProjectionActor.swift",
        (
            "$0.notes?.contains(workoutPlanPrefix) == true",
            "$0.notes?.contains(trainingPlanPrefix) == true",
            "FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)",
        ),
        errors,
    )
    require(
        "Densoso/Application/Workout/TrainingPlanSchedulingService.swift",
        (
            "static let pageSize = 10",
            "func confirmedPlansPage(offset: Int) throws -> ConfirmedPlanPage<ConfirmedTrainingPlanEntry>",
            "let prefix = ConfirmedTrainingPlanEntry.notesPrefix",
            "$0.notes?.contains(prefix) == true",
            "private static let confirmedPlanFetchBatchSize = 64",
            "private func fetchConfirmedPlanEvents(in context: ModelContext) throws -> [ScheduleEvent]",
            "descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize",
            "descriptor.fetchOffset = offset",
            "descriptor.fetchLimit = ConfirmedPlanPageSizing.pageSize + 1",
            "FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)",
        ),
        errors,
    )
    require(
        "Densoso/Services/WorkoutPlanCompiler.swift",
        (
            "func confirmedPlansPage(offset: Int) throws -> ConfirmedPlanPage<ConfirmedWorkoutPlanEntry>",
            "let singlePlanPrefix = ConfirmedWorkoutPlanEntry.notesPrefix",
            "let multiPlanPrefix = ConfirmedTrainingPlanEntry.notesPrefix",
            "func upcomingConfirmedPlans(from startDate: Date, limit: Int)",
            "$0.date >= startDate && $0.notes?.contains(prefix) == true",
            "descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize",
            "$0.notes?.contains(singlePlanPrefix) == true",
            "$0.notes?.contains(multiPlanPrefix) == true",
            "FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)",
            "func confirmedTrainingPlansPage(offset: Int) throws -> ConfirmedPlanPage<ConfirmedTrainingPlanEntry>",
        ),
        errors,
    )
    require(
        "DensosoTests/Application/DailyLoopSnapshotCompositionTests.swift",
        (
            "testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
            "testComposerMarksOldHealthBriefStaleAndChangesFingerprintWithItsSource",
            "testComposerCarriesSafeErrorStateWithoutPublishingHealthFingerprint",
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
            "testConfirmedPlanHistoryPagesAcrossThe64EventBoundary",
            "testUpcomingTrainingSessionsAreBoundedAndOrderedAcrossPages",
            "testConfirmedPlanPagesKeepAllRowsAcrossTiedTenRowBoundaries",
        ),
        errors,
    )
    require(
        "DensosoTests/WorkoutPlanSchedulingServiceTests.swift",
        (
            "testUpcomingPlansAreBoundedOrderedAndSkipTerminalEntries",
            "testTransientWorkoutKitFailureLeavesAUserRetryableScheduleIntent",
            "XCTAssertEqual(firstState, .retryable)",
            "XCTAssertEqual(finalState, .scheduled)",
        ),
        errors,
    )
    require(
        "DensosoTests/WorkoutPlanCompilerTests.swift",
        ("testWorkoutKitErrorsUseSharedCodesAndSafeMessages",),
        errors,
    )
    require(
        "DensosoTests/Application/TrainingPlanScheduleQueryTests.swift",
        ("testGetScheduleExpandsConfirmedTrainingPlanForRequestedDayIncludingRestDay",),
        errors,
    )
    require(
        "DensosoTests/Application/HealthProjectionActorTests.swift",
        (
            "testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents",
            "testConfirmedPlanEntriesPageHistoricalPlansAndDailySnapshotRetainsOnlyCurrentSessions",
            "testDailyLoopSnapshotRetainsTenEarliestPlanSessionsAcrossPages",
        ),
        errors,
    )
    require(
        "Densoso/Services/HealthProjectionActor.swift",
        (
            "dailyLoopMetricCoverage(on: date)",
            "DailyMetricsReadModelMapper.make(metric)",
            "intake: result.intake.availability",
            "expenditure: result.expenditure.availability",
            "dailyBriefValidatedAt: date",
            "dailyBriefValidatedAt: nil",
            "func confirmedPlanEntries() throws -> ConfirmedDailyLoopPlans",
            "private static let confirmedPlanFetchBatchSize = 64",
            "private static let watchPlanSummaryLimit = 10",
            "loadConfirmedPlanEntries(asOf: date)",
            "descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize",
            "descriptor.fetchOffset = offset",
            "Self.retainEarliestWatchPlanCandidates(&watchPlanCandidates)",
            "ConfirmedWorkoutPlanEntry.decode(notes: event.notes)",
            "ConfirmedTrainingPlanEntry.decode(notes: event.notes)",
            "FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)",
        ),
        errors,
    )
    require(
        "Densoso/Services/HealthIntelligenceService.swift",
        (
            "private(set) var dailyBriefSourceFingerprint: String?",
            "private(set) var dailyBriefValidatedAt: Date?",
            "dailyBriefValidatedAt = snapshot.dailyBriefValidatedAt",
            "dailyBriefValidatedAt = cached.dailyBriefValidatedAt",
        ),
        errors,
    )
    require(
        "Densoso/Application/DailyLoop/DailyLoopSnapshotService.swift",
        (
            "func snapshot(asOf date: Date = Date()) async throws -> DailyLoopSnapshot",
            "try await healthProjectionActor.dailyLoopSnapshot(",
            "dailyBriefSourceFingerprint: healthIntelligenceService.dailyBriefSourceFingerprint",
            "dailyBriefValidatedAt: healthIntelligenceService.dailyBriefValidatedAt",
            "func refreshSnapshot(asOf date: Date = Date()) async throws -> DailyLoopSnapshot",
            "healthIntelligenceService.refresh(asOf: date)",
            "pendingActions: agentSession.pendingActions",
        ),
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
            "event.notes?.contains(trainingPlanPrefix) == true",
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
                "--filter DailyHealthSampleSummaryTests",
                "--filter HealthStateTests",
                "--filter DailyLoopSnapshotTests",
                "--filter HealthNarrativeTests",
                "--filter SharedErrorDescriptorTests",
                "-only-testing:DensosoTests/HealthRepositoryTests/testInsertAndDeleteReprojectsTheSameDay",
                "-only-testing:DensosoTests/HealthRepositoryTests/testConfirmedFoodHistoryRepositoryPagesMealsAndDeduplicatesFoodIDs",
                "-only-testing:DensosoTests/HealthRepositoryTests/testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion",
                "-only-testing:DensosoTests/HealthRepositoryTests/testPendingDeletedSampleIndexesFinishCleanupAcrossMutatingPages",
                "-only-testing:DensosoTests/HealthKitSyncCoordinatorTests/testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder",
                "-only-testing:DensosoTests/HealthRepositoryTests/testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches",
                "-only-testing:DensosoTests/HealthRepositoryTests/testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable",
                "-only-testing:DensosoTests/HealthRepositoryTests/testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown",
                "-only-testing:DensosoTests/HealthRepositoryTests/testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays",
                "-only-testing:DensosoTests/HealthRepositoryTests/testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner",
                "-only-testing:DensosoTests/ConfirmationCoordinatorTests/testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision",
                "-only-testing:DensosoTests/ConfirmationCoordinatorTests/testHistoricalConfirmationKeepsPendingMetricsWhenProfileAndWeightAreMissing",
                "-only-testing:DensosoTests/HealthKitSyncCoordinatorTests/testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",
                "-only-testing:DensosoTests/HealthKitSyncCoordinatorTests/testOneFailedStreamDoesNotBlockOtherHealthMetrics",
                "-only-testing:DensosoTests/HealthSyncOutboxWorkerTests/testRetryReusesStableSyncIdentifierAndVersion",
                "-only-testing:DensosoTests/HealthSyncOutboxWorkerTests/testInterruptedSendingEntryIsRecoveredAndRetried",
                "-only-testing:DensosoTests/HealthSyncOutboxWorkerTests/testInterruptedOutboxRecoveryAndProcessingPagePastBoundedBatch",
                "-only-testing:DensosoTests/BriefNotificationSchedulerTests/testNotificationErrorsExposeSharedSafeDescriptors",
                "-only-testing:DensosoTests/CaloricEnergySemanticsTests/testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics",
                "-only-testing:DensosoTests/DailyMetricsProjectionFingerprintTests/testUnchangedFingerprintSkipsWriteButPendingLegacyMetricIsReprojected",
                "-only-testing:DensosoTests/DailyMetricsProjectionFingerprintTests/testSourceCursorProfileAndGoalRevisionsChangeProjectionFingerprint",
                "-only-testing:DensosoTests/DailyMetricsProjectionFingerprintTests/testUnrelatedHealthKitCursorDoesNotInvalidateDailyMetricsProjection",
                "-only-testing:DensosoTests/DailyMetricsProjectionFingerprintTests/testWorkoutEnergyAndProvenanceChangesProjectionFingerprint",
                "-only-testing:DensosoTests/HealthIntelligenceServiceTests/testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash",
                "-only-testing:DensosoTests/HealthProjectionActorTests",
                "-only-testing:DensosoTests/DailyLoopBackgroundSchedulerTests",
                "-only-testing:DensosoTests/HistoricalMetricsRecomputeServiceTests",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerMarksOldHealthBriefStaleAndChangesFingerprintWithItsSource",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerCarriesSafeErrorStateWithoutPublishingHealthFingerprint",
                "-only-testing:DensosoTests/HealthNarrativePolicyTests",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary",
            ),
        ),
        12: (
            "gate-12-multimodal-agent",
            (
                "--filter InputEnvelopeTests",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence",
                "-only-testing:DensosoTests/AgentCoordinatorTests/testVoiceInputEnvelopePersistsOnlySafeMetadataAndIsOmittedFromProviderMessages",
                "-only-testing:DensosoTests/AgentCoordinatorTests/testTypedEventStreamPreservesOrderAndRealCounts",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testEvidenceOnlyRequestUsesEphemeralProviderMessageWithoutImageConsentOrPersistence",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testInterruptedEvidenceOnlyRequestRequiresNewRequestToReprovideEvidence",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testEvidenceOnlyRequestBoundsTransientEvidence",
                "-only-testing:DensosoTests/MultimodalAgentImageTests/testImageRequiresVisionCapabilityAndSeparateMealImageConsent",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testMealCaptureErrorsExposeSharedSafeDescriptors",
                "-only-testing:DensosoTests/AgentUIStateMachineTests/testAgentEventsMoveThroughThinkingToolDraftConfirmationCommitAndFailureStates",
                "-only-testing:DensosoTests/AgentUIStateMachineTests/testVoiceUIStateMapsExistingSpeechCaptureStatesAndFailureKinds",
                "-only-testing:DensosoTests/MealImageCaptureStateMachineTests/testOpenPhotoRequiresConsentBeforeUploadAndMovesThroughVisionResolution",
                "-only-testing:DensosoTests/MealImageCaptureStateMachineTests/testLocalResolutionAndCancellationNeverBecomeUploadable",
                "-only-testing:DensosoTests/IntelligenceRoutingPolicyTests/testDefaultModeIsCloudDeepSeek",
                "-only-testing:DensosoTests/IntelligenceRoutingPolicyTests/testDeepSeekVisionCapabilityIsScopedToDocumentedModelAndEndpoint",
                "-only-testing:DensosoTests/IntelligenceRoutingPolicyTests/testCloudRequiresExplicitCloudMode",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testLocalOnlyBarcodeScanNeverCallsPackagedFoodProvider",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testOptionalQwenOpenPhotoRequiresSeparateQwenConsent",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testDeepSeekPhotoModeNeverFallsThroughToOptionalQwenVision",
                "-only-testing:DensosoTests/MealCaptureApplicationServiceTests/testDefaultClosedQualityGateRequiresManualFallbackWithoutStaging",
                "-only-testing:DensosoTests/FoodDatabaseTests/testCatalogEntriesRemainStableAcrossRepeatedReads",
                "-only-testing:DensosoTests/SpeechCaptureStateMachineTests/testLocalOnlyModeNeverUsesQwenFallbackEvenWhenFallbackAndConsentAreEnabled",
                "-only-testing:DensosoTests/DeepSeekProviderContractTests/testImageStructuredOutputAndStatelessToolHistoryEncoding",
                "-only-testing:DensosoTests/DeepSeekProviderContractTests/testImageMustBeInUserMessageAndFailsBeforeNetwork",
                "-only-testing:DensosoTests/AppLaunchConfigurationTests/testSeededProfileRequiresUITestMode",
                "-only-testing:DensosoTests/AppLaunchConfigurationTests/testUITestArgumentsEnableDeterministicSeed",
                "-only-testing:DensosoTests/QwenASRProviderContractTests/testOpenAICompatibleAudioRequestAndResponseContract",
                "-only-testing:DensosoTests/QwenMealVisionProviderContractTests/testPinnedQwen37SnapshotUsesImageAndStructuredObservationContract",
                "-only-testing:DensosoTests/DiagnosticsExportPrivacyTests/testProviderErrorsExportOnlyAllowlistedCodes",
                "-only-testing:DensosoTests/AgentRequestResumeTests/testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage",
                "-only-testing:DensosoTests/AgentRequestResumeTests/testLegacyV1ConversationRestoresWithCurrentToolsAndAdvancesOnNewTurn",
                "-only-testing:DensosoTests/AgentRequestResumeTests/testPerRequestCostReservationPersistsAndCannotResetOnResume",
                "-only-testing:DensosoTests/AgentRequestResumeTests/testLegacyInterruptedRequestWithoutProviderIdentityFailsClosedBeforeCall",
                "-only-testing:DensosoTests/AgentCoordinatorTests/testUnpricedProviderRequestCompletesWithUnavailableCostAccounting",
                "-only-testing:DensosoTests/AgentCoordinatorTests/testCostCapIsReservedBeforeProviderOrToolInvocation",
                "-only-testing:DensosoTests/AgentProviderContextPolicyTests",
                "-only-testing:DensosoTests/ProviderUsageLedgerTests/testPreflightCostUsesInputUpperBoundMaximumOutputAndRetryAttempts",
                "-only-testing:DensosoTests/ProviderUsageLedgerTests/testUsageIdentityImageCountAndLatencyAreRetainedInLedgerSummary",
                "-only-testing:DensosoTests/ProviderUsageLedgerTests/testUsageWithMismatchedRequestIdentityIsRejectedBeforePersistence",
                "-only-testing:DensosoTests/ProviderUsageLedgerTests/testLegacyUsagePayloadDecodesWithUnknownImageAndLatencyMetadata",
                "-only-testing:DensosoTests/DensosoMigrationTests/testV6ToV7PreservesLegacyConversationAndRestoresToolSchemaV1",
                "-only-testing:DensosoTests/DensosoMigrationTests/testV7ToV9PreservesHealthKitSampleIndexState",
                "-only-testing:DensosoTests/DensosoMigrationTests/testV8MigrationMarksPriorRoundRequestCostUnavailableWithoutProviderIdentity",
                "-only-testing:DensosoTests/DensosoMigrationTests/testV1DiskFixtureMigratesToCurrentSchemaWithoutRecalculation",
                "-only-testing:DensosoTests/DensosoMigrationTests/testV2DiskFixtureMigratesToCurrentSchemaAndPreservesCursorAndOutbox",
                "-only-testing:DensosoTests/DensosoMigrationTests/testV3MigrationToCurrentSchemaCreatesTimeAwareProfileAndWeightRecords",
                "-only-testing:DensosoTests/DensosoMigrationTests/testPersistenceBootstrapErrorsUseSafeReadOnlyDescriptor",
                "-only-testing:DensosoTests/ConfirmationCoordinatorTests/testConfirmedActionTraceabilityLinksReceiptLocalRecordAndOutbox",
                "-only-testing:DensosoTests/MealRecordAuditPresentationTests/testMealRecordPresentationShowsSanitizedSourcesAndAlgorithmVersion",
                "-only-testing:DensosoTests/PromptVersioningTests/testPromptAndToolSchemaVersionsMatchMainPR111And112",
            ),
        ),
        13: (
            "gate-13-energy-accounting",
            (
                "--filter EnergyAccountingTests",
                "--filter DailyMetricsUsabilityTests",
                "-only-testing:DensosoTests/CaloricEnergySemanticsTests/testMeasuredActiveEnergyIsNotAddedToWorkoutEnergy",
                "-only-testing:DensosoTests/CalorieEstimatorTests/testInferredOilProducesAnHonestInterval",
                "-only-testing:DensosoTests/CalorieEstimatorTests/testDeterministicMealEstimateReportsP50P95AgainstLatencyTarget",
                    "-only-testing:DensosoTests/WeeklyAnalyticsServiceTests",
            ),
        ),
        14: (
            "gate-14-watch-daily-loop",
            (
                "--filter TrainingPlanDraftTests",
                "--filter WatchMessageOutboxTests",
                "--filter WatchWorkoutCoordinatorTests",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerMarksOldHealthBriefStaleAndChangesFingerprintWithItsSource",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testComposerCarriesSafeErrorStateWithoutPublishingHealthFingerprint",
                "-only-testing:DensosoTests/DailyLoopSnapshotCompositionTests/testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testConfirmedPlanHistoryPagesAcrossThe64EventBoundary",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testUpcomingTrainingSessionsAreBoundedAndOrderedAcrossPages",
                "-only-testing:DensosoTests/TrainingPlanSchedulingServiceTests/testConfirmedPlanPagesKeepAllRowsAcrossTiedTenRowBoundaries",
                "-only-testing:DensosoTests/WorkoutPlanSchedulingServiceTests/testConfirmedScheduleIsIdempotentAcrossRetries",
                "-only-testing:DensosoTests/WorkoutPlanSchedulingServiceTests/testTransientWorkoutKitFailureLeavesAUserRetryableScheduleIntent",
                "-only-testing:DensosoTests/WorkoutPlanSchedulingServiceTests/testUpcomingPlansAreBoundedOrderedAndSkipTerminalEntries",
                "-only-testing:DensosoTests/WorkoutPlanCompilerTests/testWorkoutKitErrorsUseSharedCodesAndSafeMessages",
                "-only-testing:DensosoTests/TrainingPlanScheduleQueryTests/testGetScheduleExpandsConfirmedTrainingPlanForRequestedDayIncludingRestDay",
                "-only-testing:DensosoTests/HealthProjectionActorTests/testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents",
                "-only-testing:DensosoTests/HealthProjectionActorTests/testConfirmedPlanEntriesPageHistoricalPlansAndDailySnapshotRetainsOnlyCurrentSessions",
                "-only-testing:DensosoTests/HealthProjectionActorTests/testDailyLoopSnapshotRetainsTenEarliestPlanSessionsAcrossPages",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testPendingCommandQueryMatchesZeroUUIDAndSkipsNilRequestIDInArrivalOrder",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testPendingInboxOrdersEqualOrdinalsByMessageIDAcrossReceiptPages",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testCausalReplayWaitsForMissingAndPendingPredecessorThenOrdersBySequence",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testRejectedAndConflictingPredecessorsRejectCausalSuccessors",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testTerminalCausalWatermarkStopsAtMissingAndPendingSequences",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testTerminalCausalWatermarkCacheTracksChangesAndRebuildsAfterStoreRestart",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testCausalTranscriptWaitsForPredecessorAndStaysPendingUntilConsumed",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testLegacyPendingCommandAndTranscriptBlockNewerCommandUntilCompleted",
                "-only-testing:DensosoTests/WatchMessageInboxStoreTests/testRecentInboxQueriesFilterStatesAndApplyLimitsInArrivalOrder",
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
