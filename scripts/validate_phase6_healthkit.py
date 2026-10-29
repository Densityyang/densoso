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
            "public enum HealthStoreClientError: Equatable, Sendable, SharedErrorDescribing",
            "public var sharedErrorDescriptor: SharedErrorDescriptor",
            "protocol HealthStoreClient: Sendable",
            "func aggregate(_ request: HealthAggregateRequest)",
            "func samples(_ request: HealthSampleRequest)",
            "func workoutChanges(from startDate: Date, after anchor: Data?)",
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
            "maskCachedHealthDataBeforeAuthorizationBoundary",
            "private func maskCachedHealthSnapshots(",
            "private func removeImportedWorkouts(",
            "private func removeImportedHealthKitWeights(",
            "private func addDailyMetricDates(",
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
            "private static func preferredImportedWorkout(_ lhs: WorkoutRecord, _ rhs: WorkoutRecord)",
            "private static let importedWorkoutBatchSize = 400",
            "importedDescriptor.fetchLimit = Self.importedWorkoutBatchSize",
            "importedDescriptor.fetchOffset = offset",
            "private func deleteWorkoutDuplicates(ids: Set<UUID>)",
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
            "private static let workoutEffortFetchBatchSize = 64",
            "private func workouts(on day: Date) throws -> [WorkoutRecord]",
            "SortDescriptor(\\WorkoutRecord.date)",
            "SortDescriptor(\\WorkoutRecord.id)",
            "descriptor.fetchLimit = Self.workoutEffortFetchBatchSize",
            "workout.date > cursorDate",
            "try latestLocalWeightKilograms(on: day)",
            "private func latestLocalWeightKilograms(on date: Date, excluding excludedWeightID: UUID? = nil)",
            "SortDescriptor(\\WeightRecord.id, order: .reverse)",
            "record.id != excludedID",
            "pendingDayKeysJSON",
            "func changedHealthSampleDays(for page: HealthSamplePage, stream: String)",
            "func pendingHealthSampleDays(stream: String)",
            "record.isTombstoned",
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
            "isTombstoned == false",
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
    require_text(
        "Densoso/Services/EffectiveProfileRevisionReader.swift",
        (
            "enum EffectiveProfileRevisionReader",
            r"SortDescriptor(\ProfileRevisionRecord.effectiveFrom, order: .reverse)",
            r"SortDescriptor(\ProfileRevisionRecord.createdAt, order: .reverse)",
            r"SortDescriptor(\ProfileRevisionRecord.id, order: .reverse)",
            "descriptor.fetchLimit = 1",
        ),
        errors,
    )

    window_policy = require_text(
        "Densoso/Application/Health/HealthDataWindowPolicy.swift",
        (
            "static let analysisLookbackDays = HealthDataWindowContract.analysisLookbackDays",
            "static let initialBackfillDays = HealthDataWindowContract.initialBackfillDays",
            "static let subjectiveCheckInLookbackDays = HealthDataWindowContract.subjectiveCheckInLookbackDays",
            "static func analysisStart(",
            "static func initialBackfillStart(",
            "static func effectiveStart(",
            "return max(policyStart, authorizationStart)",
            "static func firstFullyAuthorizedDay(",
            "static func requiresRebaseline(",
            "protocol HealthAuthorizationBoundaryProviding: Sendable",
        ),
        errors,
    )
    require_text(
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthDataWindowContract.swift",
        (
            "public static let analysisLookbackDays = 42",
            "public static let initialBackfillDays = 42",
            "public static let subjectiveCheckInLookbackDays = 7",
            "public static func startOfWindow(",
        ),
        errors,
    )
    sync_coordinator = require_text(
        "Densoso/Application/Health/HealthKitSyncCoordinator.swift",
        (
            "lookbackStart", "endDate: .distantFuture", "forceRebaseline",
            "failedStreams[metric]", "completedStreams.insert(metric)",
            "onObserverSyncCompleted", "await self.onObserverSyncCompleted?(metric, scanGeneration)",
            "requerySampleDays(",
            "private func requerySampleDays(",
            "HealthDataWindowPolicy.initialBackfillStart",
            "HealthDataWindowPolicy.effectiveStart",
            "HealthDataWindowPolicy.requiresRebaseline",
            "maskCachedHealthDataIfNeeded(",
            "markHealthWindowUnknown(",
            "var streamsToReset = Set<String>()",
            "streamsToReset.insert(stream)",
            "for stream in streamsToReset.sorted()",
            "try await repository.resetHealthKitCursor(for: stream)",
            "if forceRebaseline {",
            "try await repository.resetHealthKitCursors()",
            "let start = min(cursor?.lookbackStart ?? plan.queryStart, plan.queryStart)",
            "authorizationBoundaryUnavailable = true",
            "if plan.authorizationBoundaryUnavailable || needsRebaseline",
            "prepareHealthKitSnapshotRebuild(",
            "anchorData: anchor",
            "cursorStart: cursor?.lookbackStart",
            "sampleDaysBeforeAuthorization(metric: metric, plan: plan, through: now)",
            "bucketsWithAuthorizationUnknowns(",
            "setHealthReadState(",
            "workoutChanges(from: start, after: anchor)",
        ),
        errors,
    )
    normalized_sync_coordinator = " ".join(sync_coordinator.split())
    allowed_page_flow = " ".join(
        """
        let allowedPage = HealthSamplePage(
            samples: page.samples.filter { $0.endDate >= allowedStart },
            deletedSampleIDs: page.deletedSampleIDs,
            nextAnchorData: page.nextAnchorData,
            hasMore: page.hasMore,
            readState: page.readState
        )
        """.split()
    )
    affected_days_flow = " ".join(
        "let affectedDays = try repository.affectedHealthSampleDays(for: allowedPage, stream: stream)".split()
    )
    if (
        allowed_page_flow not in normalized_sync_coordinator
        or affected_days_flow not in normalized_sync_coordinator
    ):
        errors.append(
            "HealthKit sync must filter limited-history samples by authorized end date, requery affected days, and retain the anchored cursor query start"
        )
    if "let allowedWorkouts = page.added.filter { $0.startedAt.addingTimeInterval($0.duration) >= allowedStart }" not in normalized_sync_coordinator:
        errors.append("HealthKit workouts crossing a limited-history boundary must be filtered by authorized end date")
    normalized_repository = " ".join(repository.split())
    repository_affected_day_union = " ".join(
        """
        func affectedHealthSampleDays(for page: HealthSamplePage, stream: String) throws -> [Date] {
            Array(Set(
                try changedHealthSampleDays(for: page, stream: stream)
                    + pendingHealthSampleDays(stream: stream)
            )).sorted()
        }
        """.split()
    )
    if repository_affected_day_union not in normalized_repository:
        errors.append("affected HealthKit sample days must include both changed and pending index days")
    health_store_client = require_text(
        "Densoso/Infrastructure/HealthKit/HealthKitHealthStoreClient.swift",
        (
            "HealthAuthorizationBoundaryProviding",
            "func earliestAuthorizedSampleDate(for metric: HealthMetricID)",
        ),
        errors,
    )
    boundary_start = health_store_client.find(
        "func earliestAuthorizedSampleDate(for metric: HealthMetricID)"
    )
    boundary_end = health_store_client.find("\n    func aggregate(", boundary_start)
    boundary_body = (
        health_store_client[boundary_start:boundary_end]
        if boundary_start >= 0 and boundary_end >= 0
        else ""
    )
    if "throw HealthStoreClientError.authorizationBoundaryUnavailable" not in boundary_body:
        errors.append("unsupported HealthKit authorization-boundary lookup must fail closed")
    if "guard #available(iOS 27.0, *) else {" not in boundary_body:
        errors.append("the Beta HealthKit authorization-boundary API must be availability-guarded for iOS 27")
    if "store.earliestAuthorizedSampleDate(for: [type])" not in boundary_body:
        errors.append("iOS 27 must query Apple's per-type earliest authorized sample date")
    if "return dates[type]" not in boundary_body:
        errors.append("the HealthKit authorization boundary must be mapped to the requested metric type")
    if "earliestPermittedSampleDate" in boundary_body:
        errors.append("HealthKit authorization boundaries must not use the unrelated systemwide permitted date")
    if "import SwiftData" in sync_coordinator:
        errors.append("application HealthKit coordinator must depend on a persistence protocol, not SwiftData")

    read_model = require_text(
        "Densoso/Services/HealthIntelligenceReadModel.swift",
        (
            "HealthDataWindowPolicy.analysisStart(through: end, calendar: calendar)",
            "projectionReadStates[metric.rawValue] = .dataUnavailableOrReadScopeUnknown",
            "guard projectionReadStates[metric.rawValue] == .available else { return nil }",
            "bodyMassReadState == .available",
            "projectionReadStates[HealthMetricID.sleepAnalysis.rawValue] == .available",
            "projectionReadStates[HealthMetricID.activeEnergy.rawValue] == .available",
            "projectionReadStates[HealthMetricID.stepCount.rawValue] == .available",
            "projectionReadStates[HealthMetricID.exerciseMinutes.rawValue] == .available",
            "healthReadStates: projectionReadStates",
        ),
        errors,
    )
    if "dataUnavailableOrReadScopeUnknown" in read_model and "== .available else { return nil }" not in read_model:
        errors.append("unknown HealthKit read states must not be consumed as observations")
    domain_coverage = require_text(
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthIntelligence.swift",
        (
            "case unknown",
            "case partial",
            "public enum HealthDataCoverage",
            "private func healthReadCoverage(",
            "guard dataCoverage == .complete else { return }",
        ),
        errors,
    )
    normalized_domain_coverage = " ".join(domain_coverage.split())
    decoded_domain_coverage = " ".join(
        """
        let decodedCoverage = try container.decodeIfPresent(HealthDataCoverage.self, forKey: .dataCoverage)
            ?? (domain == .nutrition ? .complete : .unknown)
        """.split()
    )
    fail_closed_unknown_domain = " ".join(
        """
        if resolvedCoverage == .unknown {
            self.status = .unknown
            self.currentValue = nil
            self.baseline = HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
            self.evidenceKeys = []
        }
        """.split()
    )
    decoded_domain_uses_coverage = " ".join(
        """
        dataCoverage: decodedCoverage
        """.split()
    )
    unknown_training_load_decode = " ".join(
        """
        let decodedCoverage = try container.decodeIfPresent(HealthDataCoverage.self, forKey: .dataCoverage) ?? .unknown
        dataCoverage = decodedCoverage
        if decodedCoverage == .complete {
            recentSevenDayLoad = try container.decodeIfPresent(Double.self, forKey: .recentSevenDayLoad) ?? 0
            priorTwentyEightDayAverage = try container.decodeIfPresent(Double.self, forKey: .priorTwentyEightDayAverage)
            ratio = try container.decodeIfPresent(Double.self, forKey: .ratio)
            readiness = try container.decode(BaselineReadiness.self, forKey: .readiness)
            band = try container.decode(TrainingLoadBand.self, forKey: .band)
            estimatedWorkoutCount = try container.decodeIfPresent(Int.self, forKey: .estimatedWorkoutCount) ?? 0
            unavailableEffortCount = try container.decodeIfPresent(Int.self, forKey: .unavailableEffortCount) ?? 0
        } else {
            recentSevenDayLoad = 0
            priorTwentyEightDayAverage = nil
            ratio = nil
            readiness = .noData
            band = .unavailable
            estimatedWorkoutCount = 0
            unavailableEffortCount = 0
        }
        """.split()
    )
    unknown_vital_trend = " ".join(
        """
        if resolvedCoverage == .unknown {
            self.latestMedian = nil
            self.baseline = HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
            self.status = .unknown
        }
        """.split()
    )
    if decoded_domain_coverage not in normalized_domain_coverage:
        errors.append("legacy health-domain cache decoding must treat absent non-nutrition coverage as unknown")
    if (
        fail_closed_unknown_domain not in normalized_domain_coverage
        or decoded_domain_uses_coverage not in normalized_domain_coverage
    ):
        errors.append("unknown health-domain coverage must clear cached status, value, baseline, and evidence")
    if unknown_training_load_decode not in normalized_domain_coverage:
        errors.append("legacy training-load caches without coverage must decode as unknown and omit numeric placeholders")
    if unknown_vital_trend not in normalized_domain_coverage:
        errors.append("unknown vital-trend coverage must clear its median and reset its baseline/status")
    if "health-intelligence-v3" not in require_text(
        "Packages/DensosoDomain/Sources/DensosoDomain/AlgorithmVersions.swift",
        ("public static let healthIntelligence = \"health-intelligence-v3\"",),
        errors,
    ):
        errors.append("health-intelligence-v3 must invalidate briefs built with the old coverage semantics")
    require_text(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/HealthIntelligenceTests.swift",
        (
            "testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial",
            "testLegacyTrainingLoadCacheWithoutCoverageDecodesUnknownAndOmitsNumericPlaceholders",
            "testLegacyHealthDomainVitalAndContextCachesFailClosedWithoutCoverage",
        ),
        errors,
    )
    require_text(
        "DensosoTests/Application/GetHealthHistoryToolTests.swift",
        (
            "testHistoryResponsePreservesUnknownAndPartialCoverageWithoutAbsenceOrZero",
            "testReadModelHistoryKeepsUnknownHealthKitCoverageTypedWithoutZeroObservations",
        ),
        errors,
    )
    require_text(
        "DensosoTests/Application/GetTodayHealthStateToolTests.swift",
        ("testUnknownTrainingLoadOmitsZeroAndDerivedValuesAndReportsCoverage",),
        errors,
    )
    require_text(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/Health/HealthStateTests.swift",
        ("testUnknownAndPartialDomainStatusesDoNotBecomeUsableRecoveryEvidence",),
        errors,
    )
    require_text(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/HealthNarrativeTests.swift",
        ("testNarrativeContextOmitsUnknownTrainingLoadZeroPlaceholders",),
        errors,
    )

    background_refresh = require_text(
        "Densoso/Application/DailyLoop/DailyLoopBackgroundScheduler.swift",
        (
            "BGTaskScheduler.shared.register(",
            "BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)",
            "backgroundTask.expirationHandler",
            "self.healthSyncCoordinator.syncAvailableData(",
            "forceRebaseline: true",
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
            "private func pendingBatch(",
            "static let outboxBatchSize = 64",
            "descriptor.fetchLimit = Self.outboxBatchSize",
            "cursorIdempotencyKey",
            "if entry.operation == \"upsertMeal\"",
            "if entry.operation == \"upsertWeight\"",
            "entry.operation == \"deleteMeal\" || entry.operation == \"deleteWeight\"",
            "HealthRepository.canonicalSyncIdentifier(",
            r"SortDescriptor(\HealthSyncOutboxEntry.createdAt)",
            "private func isSuperseded(_ entry: HealthSyncOutboxEntry, in modelContext: ModelContext) throws -> Bool",
            "candidate.syncVersion > minimumSyncVersion",
            "candidate.createdAt > cursorCreatedAt",
            "candidate.idempotencyKey > cursorIdempotencyKey",
            "private func updateActionReceipt(for entry: HealthSyncOutboxEntry",
            "predicate: #Predicate { $0.id == receiptID }",
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
            "EnergyAccounting.calculate(",
            "let expenditure = energyAccounting.expenditure",
            "let active = energyAccounting.activeComponent?.likely",
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
        "DensosoWatchApp/WatchHealthKitWorkoutManager.swift",
        "DensosoWatchApp/DensosoWatchExtension.entitlements",
    ):
        if (ROOT / removed).exists():
            errors.append(f"obsolete importer remains: {removed}")

    require_text(
        "DensosoTests/HealthKitSyncCoordinatorTests.swift",
        (
            "testObserverCompletionRunsAfterAnchoredWorkoutIsCommitted",
            "testInitialHealthKitBackfillUsesTheSame42DayWindowForEveryStreamType",
            "testLimitedHealthKitHistoryStartsAtAuthorizationBoundaryAndRecordsUnknownDays",
            "testLimitedHistoryRetainsSamplesAndWorkoutsEndingAfterAuthorizationBoundary",
            "testUnavailableAuthorizationBoundaryRebuildsWindowAndKeepsEmptyDaysUnknown",
            "testObserverWithUnavailableBoundaryRebuildsExistingSampleAndWorkoutAnchors",
            "testReadModelHidesAggregateHealthValuesWhenTheirReadStatesAreUnknown",
            "testAuthorizationBoundaryAdvanceRebaselinesAndExcludesPreviouslyIndexedSamples",
            "olderSampleDay",
            "HealthKitWeightObservationReader.latestObservation(in: context, effectiveAt: now)",
            "staleWorkout.healthKitUUID",
            "testSubsequentSampleSyncUsesStoredAnchorInsteadOfReplayingThe42DayWindow",
            "testStoredSampleAnchorAppliesLateSamplesBeforeCurrentWindowStart",
            "testDeletedSampleBeforeCurrentWindowStartRequeriesHistoricalDay",
            "testShortExistingSampleWindowRebaselinesIdempotentlyTo42Days",
            "testHealthDataWindowPolicyUses42InclusiveDaysAndRespectsAuthorizationBoundary",
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
        "DensosoTests/HealthRepositoryTests.swift",
        ("testMeasuredDailyActivityAggregateFeedsProjectionWithoutWorkoutEnergy",),
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
            "testInterruptedOutboxRecoveryAndProcessingPagePastBoundedBatch",
            "testSupersessionCheckPagesPast64SameRecordRows",
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
            "testImportedWorkoutDedupProcessesUUIDGroupsAcrossFetchBatchBoundary",
            "testOutboxEnqueueReadsMatchingVersionsAndLatestReceiptAmongManyRows",
            "testDeletingLatestSameDayWeightFallsBackToNextLocalThenHealthKitWeight",
            "testBodyMassReplacementPrefersLatestSameDayLocalWeightOverHealthKitSummary",
            "testWorkoutEffortReprojectionPagesSameDayWorkoutsAcross64RowBoundary",
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
        (
            "testMealConfirmationPreservesMeasuredHealthKitEnergyProjection",
            "testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision",
            "restingEnergyKcal: 1_410",
        ),
        errors,
    )
    watch_app = require_text(
        "DensosoWatchApp/DensosoWatchCompanionApp.swift",
        ("DensosoWatchCompanionApp", "WatchCompanionView"),
        errors,
    )
    watch_view = require_text(
        "DensosoWatchApp/WatchCompanionView.swift",
        ("WatchCompanionView", "connectivity.sendTranscript", "pendingActionsSection(asOf"),
        errors,
    )
    if "connectivity.confirm" in watch_view or "connectivity.reject" in watch_view:
        errors.append("Watch must not expose pending-action confirmation or rejection controls")
    phone_watch = require_text(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
        ("case .confirm, .reject:", "rejectPendingMessage("),
        errors,
    )
    confirmation_branch = phone_watch.partition("case .confirm, .reject:")[2].partition("case .acknowledgement")[0]
    if "rejectPendingMessage(" not in confirmation_branch:
        errors.append("iPhone must reject Watch-originated pending-action confirmation and rejection")
    if any(token in watch_app + watch_view for token in ("import HealthKit", "HKWorkout")):
        errors.append("Watch extension must not host a custom HealthKit Workout writer")
    require_text(
        "Densoso/App/DensosoApp.swift",
        (
            "dependencies.healthKitSyncCoordinator.syncAvailableData(",
            "forceRebaseline: true",
        ),
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
        ("approved by user after successful macOS CI", "HealthKit delivery workers remain Phase 6."),
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
        "windowContract": {
            "evidenceLevel": "static-source-and-test-presence",
            "analysisLookbackDays": 42,
            "initialBackfillDays": 42,
            "authorizationBoundaryContractPresent": True,
            "betaAPI": "IOS_27_PER_TYPE_AUTHORIZATION_BOUNDARY",
            "unsupportedOSAuthorizationBoundaryFallback": "FAIL_CLOSED_UNKNOWN_WITH_TYPED_ERROR",
            "anchoredIncrementalContractPresent": True,
            "runtimeTestExecution": "NOT_MEASURED",
            "liveHealthKitAuthorizationBoundary": "NOT_MEASURED",
            "unknownCoverageSemantics": {
                "sourceContract": "PASS",
                "localSemanticTestPresence": "PASS",
                "localTestExecution": "NOT_MEASURED",
                "liveHealthKitAuthorizationEvidence": "NOT_MEASURED",
                "swiftPackageFilters": [
                    "HealthIntelligenceTests/testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial",
                    "HealthIntelligenceTests/testLegacyTrainingLoadCacheWithoutCoverageDecodesUnknownAndOmitsNumericPlaceholders",
                    "HealthIntelligenceTests/testLegacyHealthDomainVitalAndContextCachesFailClosedWithoutCoverage",
                    "HealthStateTests/testUnknownAndPartialDomainStatusesDoNotBecomeUsableRecoveryEvidence",
                    "HealthNarrativeTests/testNarrativeContextOmitsUnknownTrainingLoadZeroPlaceholders",
                ],
                "xcodebuildSelectors": [
                    "GetHealthHistoryToolTests/testHistoryResponsePreservesUnknownAndPartialCoverageWithoutAbsenceOrZero",
                    "GetHealthHistoryToolTests/testReadModelHistoryKeepsUnknownHealthKitCoverageTypedWithoutZeroObservations",
                    "GetTodayHealthStateToolTests/testUnknownTrainingLoadOmitsZeroAndDerivedValuesAndReportsCoverage",
                ],
            },
        },
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
