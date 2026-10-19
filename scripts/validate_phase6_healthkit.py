#!/usr/bin/env python3
"""Validate Phase 6 HealthKit contracts through explicit source paths only."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require_text(relative: str, needles: tuple[str, ...], errors: list[str]) -> str:
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"missing {relative}")
        return ""
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            errors.append(f"{relative} is missing {needle}")
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    args = parser.parse_args()
    errors: list[str] = []

    contracts = require_text(
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthKitContracts.swift",
        (
            "public enum HealthStoreClientError: LocalizedError, Equatable, Sendable",
            "protocol HealthStoreClient: Sendable",
            "func aggregate(_ request: HealthAggregateRequest)",
            "func samples(_ request: HealthSampleRequest)",
            "func workoutChanges(after anchor: Data?)",
            "func save(_ command: HealthWriteCommand)",
            "func deleteOwnSample(receipt: HealthWriteReceipt)",
            "func enableBackgroundDelivery(for streams: Set<HealthMetricID>)",
            "public static func preferredForDeduplication",
            "public static func stableDeduplicationOrder",
            "public static func deduplicated(_ samples: [Self])",
            "protocol HealthObserverClient: Sendable",
            "dataUnavailableOrReadScopeUnknown",
        ),
        errors,
    )
    if "readDenied" in contracts or "case denied" in contracts:
        errors.append("HealthKit read authorization must not expose a denied state")

    snapshot_contract = require_text(
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthDomainDrafts.swift",
        (
            'public static let currentAlgorithmVersion = "daily-health-snapshot-v2"',
            "public let healthKitSampleSummary: DailyHealthSampleSummary?",
            "case healthKitSamples",
            "try container.encodeIfPresent(healthKitSampleSummary, forKey: .healthKitSampleSummary)",
            "private static func inferredReadStates",
        ),
        errors,
    )
    if "try container.encodeIfPresent(healthKitSamples" in snapshot_contract:
        errors.append("daily HealthKit cache must not encode raw sample payloads")

    summary_domain = require_text(
        "Packages/DensosoDomain/Sources/DensosoDomain/Health/DailyHealthSampleSummary.swift",
        (
            "public struct DailyHealthSampleSummary",
            "public struct HealthMetricSampleAggregate",
            "public struct WorkoutEffortDailyAggregate",
            "public let metrics: [HealthMetricSampleAggregate]",
            "public let sleep: SleepSummary?",
            "public let workoutEffort: [WorkoutEffortDailyAggregate]",
        ),
        errors,
    )
    if "public let samples: [HealthSampleSnapshot]" in summary_domain:
        errors.append("daily summaries must aggregate samples without retaining raw HealthKit payloads")

    v6_schema = require_text(
        "Densoso/Persistence/Schemas/DensosoSchemaV6.swift",
        (
            "static var versionIdentifier: Schema.Version { .init(6, 0, 0) }",
            "DensosoSchemaV5.models + [HealthKitSampleIndexRecord.self]",
            "@Attribute(.unique) var sampleID: UUID",
            "var stream: String",
            "var dayKey: String",
            "var startDate: Date",
            "var endDate: Date",
            "var needsRequery: Bool",
            "var pendingDayKeysJSON: String",
            "var isDeleted: Bool",
        ),
        errors,
    )
    if "HealthSampleSnapshot" in v6_schema:
        errors.append("V6 sample index must not persist complete HealthKit sample payloads")

    migration = require_text(
        "Densoso/Persistence/DensosoMigrationPlan.swift",
        (
            "fromVersion: DensosoSchemaV5.self",
            "toVersion: DensosoSchemaV6.self",
            "try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)",
            "DailyHealthSnapshot.currentAlgorithmVersion",
            "let legacySamples = HealthSampleSnapshot.deduplicated(",
            "DensosoSchemaV6.HealthKitSampleIndexRecord(",
            "private static func sleepWakeDays(startDate: Date, endDate: Date)",
        ),
        errors,
    )

    health_store = require_text(
        "Densoso/Infrastructure/HealthKit/HealthKitHealthStoreClient.swift",
        (
            "HKStatisticsCollectionQuery",
            "HKAnchoredObjectQuery",
            "HKObserverQuery",
            "guard error == nil else",
            "observerKeys.insert(key)",
            "HKMetadataKeySyncIdentifier",
            "HKMetadataKeySyncVersion",
            "HKQuery.predicateForObjects",
            "HKHealthStore.isHealthDataAvailable()",
            "errorAuthorizationNotDetermined",
            "dataStoreLocked",
            "healthDataRestricted",
        ),
        errors,
    )
    if "workoutRoute" in health_store or "HKSeriesType" in health_store:
        errors.append("HealthKit adapter must not query workout routes")
    sleep_category = health_store.partition("private static func sleepCategoryName")[2].partition(
        "\n    private static func"
    )[0]
    if not sleep_category:
        errors.append("HealthKit sleep category names must remain explicitly mapped")
    elif r'\"' in sleep_category:
        errors.append("HealthKit sleep category return strings must not contain escaped source quotes")

    repository = require_text(
        "Densoso/Services/HealthRepository.swift",
        (
            "applyImportedHealthSamples",
            "applyHealthAggregates",
            "resetHealthKitCursors",
            "func update(_ meal: MealRecord)",
            "func update(_ weight: WeightRecord",
            "func delete(_ weight: WeightRecord)",
            "canonicalSyncIdentifier",
            "private func healthSnapshotRecord(dayKey: String)",
            "#Predicate<DailyHealthSnapshotRecord>",
            "descriptor.fetchLimit = 1",
            "private func cursorRecord(stream: String)",
            "#Predicate<HealthKitImportCursor>",
            "#Predicate<WorkoutRecord> { $0.healthKitUUID != nil }",
            "workoutsByHealthKitUUID[healthKitUUID] == nil",
            "private static func preferredImportedWorkout(_ lhs: WorkoutRecord, _ rhs: WorkoutRecord)",
            "lastSuccessfulAt",
            "modelContext.rollback()",
            "func affectedHealthSampleDays(for page: HealthSamplePage, stream: String)",
            "replacements: [HealthSampleDaySnapshot]",
            "HealthKitSampleIndexRecord",
            "needsRequery",
            "private static func sleepWakeDays(startDate: Date, endDate: Date)",
            "private static let healthKitSampleIndexBatchSize = 400",
            "private func forEachPendingHealthKitSampleIndex(",
            "descriptor.fetchLimit = Self.healthKitSampleIndexBatchSize",
            "descriptor.fetchOffset = offset",
            "pendingDayKeysJSON",
            "record.isDeleted",
            "availableDayKeys",
            "let bucketsByDay = Dictionary(",
            "for (day, bucket) in bucketsByDay",
        ),
        errors,
    )
    if 'enqueue(operation: "upsertWorkout"' in repository or 'enqueue(operation: "deleteWorkout"' in repository:
        errors.append("workouts must never enter the HealthKit outbox")

    weight_reader = require_text(
        "Densoso/Services/HealthKitWeightObservationReader.swift",
        (
            "enum HealthKitWeightObservationReader",
            "private static let batchSize = 128",
            "descriptor.fetchLimit = batchSize",
            "descriptor.fetchOffset = offset",
            "HealthKitSampleIndexRecord",
            "isDeleted == false",
            "healthReadStates",
            "batchDayKeys.contains($0.dayKey)",
            "let snapshotRecords = try modelContext.fetch(",
        ),
        errors,
    )
    require_text(
        "Densoso/Services/LocalWeightObservationReader.swift",
        (
            "enum LocalWeightObservationReader",
            "private static let batchSize = 128",
            "descriptor.fetchLimit = batchSize",
            "descriptor.fetchOffset = offset",
            "observation.isValid",
        ),
        errors,
    )

    sync_coordinator = require_text(
        "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
        (
            "lookbackStart", "endDate: .distantFuture", "forceRebaseline", "value: -30",
            "failedStreams[metric]", "completedStreams.insert(metric)",
            "onObserverSyncCompleted", "self.onObserverSyncCompleted?()",
            "repository.affectedHealthSampleDays(for: page, stream: stream)",
            "requerySampleDays(",
            "private func requerySampleDays(",
            "replacements: replacements",
        ),
        errors,
    )
    if "import SwiftData" in sync_coordinator:
        errors.append("application HealthKit coordinator must depend on a persistence protocol, not SwiftData")

    background_refresh = require_text(
        "Densoso/Application/DailyLoop/DailyLoopBackgroundScheduler.swift",
        (
            "BGTaskScheduler.shared.register(",
            "BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)",
            "task.expirationHandler",
            "syncAvailableData(using: repository)",
            "self.healthIntelligenceService.refresh()",
            "self.dailyLoopSnapshotService.snapshot()",
            "updateSnapshot(snapshot)",
            "refreshApplicationContext()",
            "guard isHealthAuthorized() else",
        ),
        errors,
    )
    if "ProviderRegistry" in background_refresh or "providerRegistry" in background_refresh:
        errors.append("background health refresh must not route through an AI provider")
    require_text(
        "project.yml",
        (
            "BGTaskSchedulerPermittedIdentifiers:",
            "com.densoso.densoso.daily-loop.refresh",
            "UIBackgroundModes:",
            "- fetch",
        ),
        errors,
    )

    outbox = require_text(
        "Densoso/Services/HealthSyncOutboxWorker.swift",
        (
            "HealthKitConnectionPreference.hasRequestedAuthorization",
            "let sendingPredicate = #Predicate<HealthSyncOutboxEntry>",
            "let eligiblePredicate = #Predicate<HealthSyncOutboxEntry>",
            r"SortDescriptor(\HealthSyncOutboxEntry.createdAt)",
            "private func isSuperseded(_ entry: HealthSyncOutboxEntry, in modelContext: ModelContext) throws -> Bool",
            "predicate: #Predicate { $0.recordID == recordID }",
            "descriptor.fetchLimit = 1",
            "HealthWritePayload.nutrition",
            ".confirmedWeight(kilograms:",
            "deleteOwnSample(receipt:",
            "syncVersion: entry.syncVersion",
            "entry.state = terminal ? \"terminal\" : \"retryable\"",
        ),
        errors,
    )
    if "upsertWorkout" in outbox and "Workout HealthKit writes are disabled" not in outbox:
        errors.append("legacy workout outbox rows must be prevented from writing")

    caloric_engine = require_text(
        "Densoso/Services/CaloricEngine.swift",
        (
            "healthKitActiveEnergyKcal",
            "healthKitRestingEnergyKcal",
            "EnergyAccounting.expenditure(",
            "max($0.likely - (basal ?? 0), 0)",
            "workoutCount: dayWorkouts.count",
        ),
        errors,
    )
    if "if !dayWorkouts.isEmpty" in caloric_engine or "dayWorkouts.map(\\.estimatedCaloriesBurned).reduce" in caloric_engine:
        errors.append("DailyMetrics must not change active-energy semantics based on workout presence")

    for removed in (
        "Densoso/Services/WorkoutRouteImporter.swift",
        "Densoso/Services/HealthKitWorkoutImporter.swift",
        "Densoso/Services/WorkoutSessionMirroringService.swift",
        "DensosoWatchExtension/WatchHealthKitWorkoutManager.swift",
        "DensosoWatchExtension/DensosoWatchExtension.entitlements",
    ):
        if (ROOT / removed).exists():
            errors.append(f"obsolete importer remains: {removed}")

    require_text(
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        (
            "testObserverCompletionRunsAfterAnchoredWorkoutIsCommitted",
            "self.context.fetch(FetchDescriptor<WorkoutRecord>())",
            "refreshSawCommittedWorkout",
            "testMeasuredDailyActivityAggregateFeedsProjectionWithoutWorkoutEnergy",
            "testEmptyAmbiguousWorkoutReadAdvancesCursorWithoutClaimingReadDenial",
            "testOneFailedStreamDoesNotBlockOtherHealthMetrics",
            "testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder",
        ),
        errors,
    )
    require_text(
        "DensosoTests/HealthSyncOutboxWorkerTests.swift",
        (
            "testConfirmedMealWritesOnlyKnownNutritionAndPersistsReceipt",
            "testRetryReusesStableSyncIdentifierAndVersion",
            "testNewerMealVersionSupersedesAnUnsentOutboxWrite",
            "testInterruptedSendingEntryIsRecoveredAndRetried",
            "testPendingQuerySkipsFutureRetriesAndTerminalRows",
            "testWeightUpdatesAndDeleteConvergeToTheNewestVersion",
            "testMealDeletionUsesOnlyItsStableApplicationSyncIdentifier",
            "testNoWriteIsAttemptedBeforeTheUserStartsHealthKitAuthorization",
        ),
        errors,
    )
    require_text(
        "DensosoTests/HealthRepositoryTests.swift",
        (
            "testCursorAndSampleProjectionRollbackTogetherWhenSaveFails",
            "testImportedWorkoutAndAnchorRollbackTogetherWhenSaveFails",
            "testImportedWorkoutDeduplicatesByHealthKitUUIDAndPersistsAnchor",
            "testHealthSamplePagesUpdateDeleteAndDeduplicateByHealthKitUUID",
            "testUpdatedSampleMovingToAnotherDayRemovesOldProjection",
            "testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue",
            "testHealthSnapshotUpsertUpdatesOnlyTheMatchingDayKey",
            "testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion",
            "testSleepDeletionTargetsOnlyWakeDaysIntersectingTheStoredInterval",
            "testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches",
            "testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown",
            "testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable",
            "testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays",
            "testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner",
            "testDuplicateHealthAggregateBucketsKeepLastBucketPerDay",
        ),
        errors,
    )
    require_text(
        "DensosoTests/DensosoMigrationTests.swift",
        ("testV5MigrationMovesRawSamplesIntoIndexAndDailySummary",),
        errors,
    )
    require_text(
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        ("testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",),
        errors,
    )
    require_text(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/DailyHealthSampleSummaryTests.swift",
        (
            "testDailySnapshotEncodingKeepsOnlySummaryAndDropsRawSamples",
            "testSleepAggregationRetainsWatchPriorityAndLegacyCategoryAliases",
            "testSampleDeduplicationUsesSyncVersionThenStableTieOrder",
        ),
        errors,
    )
    require_text(
        "DensosoTests/ConfirmationCoordinatorTests.swift",
        ("testMealConfirmationPreservesMeasuredHealthKitEnergyProjection", "restingEnergyKcal: 1_410"),
        errors,
    )
    watch_app = require_text(
        "DensosoWatchExtension/DensosoWatchCompanionApp.swift",
        ("DensosoWatchCompanionApp", "WatchCompanionView"),
        errors,
    )
    watch_view = require_text(
        "DensosoWatchExtension/WatchCompanionView.swift",
        ("WatchCompanionView", "connectivity.sendTranscript", "connectivity.confirm", "connectivity.reject"),
        errors,
    )
    if any(token in watch_app + watch_view for token in ("import HealthKit", "HKWorkout")):
        errors.append("Watch extension must not host a custom HealthKit Workout writer")
    require_text(
        "Densoso/App/DensosoApp.swift",
        ("healthKitSyncCoordinator.syncAvailableData(using: healthRepository)",),
        errors,
    )
    require_text(
        "docs/gates/gate-06-healthkit.md",
        (
            "Status:",
            "no read permission denial",
            "Gate 6 does not claim",
            "Weight edit/delete controls are not added",
            "V5-to-V6 daily sample summary",
            "testV5MigrationMovesRawSamplesIntoIndexAndDailySummary",
            "testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor",
            "testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder",
            "testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches",
            "testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown",
            "testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable",
            "testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays",
            "testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner",
        ),
        errors,
    )
    require_text(
        "docs/gates/gate-05-meal-capture.md",
        ("Status: approved by user after successful macOS CI", "Approved by user; Phase 6 may proceed"),
        errors,
    )
    require_text(
        "Densoso/Densoso.entitlements",
        ("com.apple.developer.healthkit", "com.apple.developer.healthkit.background-delivery"),
        errors,
    )
    if "com.apple.developer.healthkit.background-delivery: true" not in require_text(
        "project.yml", ("com.apple.developer.healthkit.background-delivery: true",), errors
    ):
        errors.append("XcodeGen target must request the HealthKit background-delivery entitlement")
    require_text(
        ".github/workflows/build.yml",
        (
            "healthkit:",
            "name: gate-06-healthkit",
            "needs: meal-capture",
            "validate_phase6_healthkit.py",
            "Gate06HealthKitTests.xcresult",
            "gate-06-healthkit-results",
        ),
        errors,
    )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "scope": "healthkit-sync-energy-semantics-and-v6-daily-sample-summary",
        "protectedOCRRead": False,
        "readAuthorizationInferred": False,
        "workoutWritesEnabled": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    print("Phase 6 HealthKit static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
