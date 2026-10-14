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
            "protocol HealthObserverClient: Sendable",
            "dataUnavailableOrReadScopeUnknown",
        ),
        errors,
    )
    if "readDenied" in contracts or "case denied" in contracts:
        errors.append("HealthKit read authorization must not expose a denied state")

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
            "workouts.sorted(by:",
            "lastSuccessfulAt",
            "modelContext.rollback()",
        ),
        errors,
    )
    if 'enqueue(operation: "upsertWorkout"' in repository or 'enqueue(operation: "deleteWorkout"' in repository:
        errors.append("workouts must never enter the HealthKit outbox")

    sync_coordinator = require_text(
        "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
        (
            "lookbackStart", "endDate: .distantFuture", "forceRebaseline", "value: -30",
            "failedStreams[metric]", "completedStreams.insert(metric)",
        ),
        errors,
    )
    if "import SwiftData" in sync_coordinator:
        errors.append("application HealthKit coordinator must depend on a persistence protocol, not SwiftData")

    outbox = require_text(
        "Densoso/Services/HealthSyncOutboxWorker.swift",
        (
            "HealthKitConnectionPreference.hasRequestedAuthorization",
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
            "max(tdee(bmr: bmrValue, activityLevel: userProfile.activityLevel) - bmrValue, 0)",
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
            "testMeasuredDailyActivityAggregateFeedsProjectionWithoutWorkoutEnergy",
            "testEmptyAmbiguousWorkoutReadAdvancesCursorWithoutClaimingReadDenial",
            "testOneFailedStreamDoesNotBlockOtherHealthMetrics",
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
            "testHealthSamplePagesUpdateDeleteAndDeduplicateByHealthKitUUID",
            "testUpdatedSampleMovingToAnotherDayRemovesOldProjection",
            "testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue",
        ),
        errors,
    )
    require_text(
        "DensosoTests/ConfirmationCoordinatorTests.swift",
        ("testMealConfirmationPreservesMeasuredHealthKitEnergyProjection", "restingEnergyKcal: 1_410"),
        errors,
    )
    watch_app = require_text(
        "DensosoWatchExtension/DensosoWatchWorkoutApp.swift",
        ("WatchCompanionPlaceholder", "Watch 伴侣功能将在后续阶段接入"),
        errors,
    )
    if "HealthKit" in watch_app or "HKWorkout" in watch_app:
        errors.append("Watch extension must not host a custom HealthKit Workout writer")
    require_text(
        "Densoso/App/DensosoApp.swift",
        ("healthKitSyncCoordinator.syncAvailableData(using: healthRepository)",),
        errors,
    )
    require_text(
        "docs/gates/gate-06-healthkit.md",
        (
            "Status: implementation candidate; awaiting macOS CI and user review",
            "no read permission denial",
            "Gate 6 does not claim",
            "Weight edit/delete controls are not added",
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
        "scope": "healthkit-sync-and-energy-semantics",
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
