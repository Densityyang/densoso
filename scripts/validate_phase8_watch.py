#!/usr/bin/env python3
"""Validate Phase 8 WatchConnectivity and WorkoutKit boundaries."""

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
        "Packages/DensosoDomain/Sources/DensosoDomain/WatchConnectivityContracts.swift",
        (
            "public struct WatchMessageEnvelope",
            "public static let currentSchemaVersion = 2",
            "public let expiresAt: Date?",
            "public enum WatchMessageExpiryPolicy",
            "public enum WatchMessageAuthorizationPolicy",
            "public enum WatchPayload",
            "public struct WatchMessageOutbox",
            "maximumPendingMessageCount = 128",
            "case messageIDCollision(UUID)",
            "maximumTranscriptLength = 4_000",
            "maximumTranscriptUTF8Bytes = 32_000",
        ),
        errors,
    )
    inbox = require_text(
        "Densoso/Infrastructure/WatchConnectivity/WatchMessageInboxStore.swift",
        (
            "func ingest(_ envelope:", "payloadHash", "WatchMessageReceiptRecord", "context.transaction {",
            "func recentReceivedMessageIDs(limit: Int = 100)",
            "func pendingCommandEnvelopes() throws -> [WatchMessageEnvelope]",
            "private static let pendingReceiptFetchBatchSize = 64",
            "private func pendingInboxMessages(in context: ModelContext) throws -> [MessageRecord]",
            "descriptor.fetchLimit = Self.pendingReceiptFetchBatchSize",
            "receipt.messageID > lastMessageID",
            "message.ordinal > cursorOrdinal",
            "messages.sorted {",
            "$0.ordinal == $1.ordinal ? $0.id < $1.id : $0.ordinal < $1.ordinal",
        ),
        errors,
    )
    phone = require_text(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
        (
            "session.updateApplicationContext", "didReceiveUserInfo", "didReceiveMessage",
            "pendingTranscriptRevision", "inboxStore.recentProcessedMessageIDs()",
            "resumePendingCommands()",
        ),
        errors,
    )
    watch = require_text(
        "DensosoWatchExtension/WatchConnectivityClient.swift",
        (
            "session.sendMessage", "session.transferUserInfo", "didReceiveApplicationContext",
            "didFinish userInfoTransfer: WCSessionUserInfoTransfer", "dispatchedIDs.removeAll()", "sendTranscript",
        ),
        errors,
    )
    require_text(
        "Densoso/Infrastructure/WatchConnectivity/WatchMessageOutboxStore.swift",
        (
            "legacyStorageKey",
            "maximumPersistedBytes",
            "data.write(to: storageURL, options: .atomic)",
            "defaults.removeObject(forKey: Self.legacyStorageKey)",
        ),
        errors,
    )
    if "func confirm(actionID:" in watch or "func reject(actionID:" in watch:
        errors.append("Watch client must not expose pending-action confirmation or rejection")
    if "enqueue(.confirm" in watch or "enqueue(.reject" in watch:
        errors.append("Watch client must not dispatch pending-action mutations")
    phone = require_text(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
        (
            "WatchMessageExpiryPolicy.isExpired(envelope, asOf: Date())",
            "WatchMessageAuthorizationPolicy.requiresPhoneConfirmation(for: envelope.payload)",
            "待确认事项必须在 iPhone 查看并处理",
        ),
        errors,
    )
    if "confirmationCoordinator.confirm(id: actionID)" in phone or "confirmationCoordinator.reject(id: actionID)" in phone:
        errors.append("Phone Watch ingress must not confirm or reject a pending action on the Watch's behalf")
    view = require_text(
        "DensosoWatchExtension/WatchCompanionView.swift",
        ("请在 iPhone 查看并确认或拒绝",),
        errors,
    )
    if 'Button("确认")' in view or 'Button("拒绝"' in view:
        errors.append("Watch pending-action UI must direct users to iPhone review")

    compiler = require_text(
        "Densoso/Services/WorkoutPlanCompiler.swift",
        (
            "private static let confirmedPlanFetchBatchSize = 64",
            "private func confirmedPlanEventDescriptor() -> FetchDescriptor<ScheduleEvent>",
            "private func findConfirmedPlanEvent(",
            "descriptor.fetchLimit = Self.confirmedPlanFetchBatchSize",
            "descriptor.fetchOffset = offset",
            "FetchDescriptor<ScheduleEvent>(predicate: predicate, sortBy: sortDescriptors)",
            "guard draft.activity.isWorkoutKitSupported",
            "guard draft.strengthSets.isEmpty",
            "scheduleDateRequired",
            "struct WorkoutKitPlanSchedulingClient",
            "WorkoutScheduler.isSupported",
            "requestAuthorization()",
            "@concurrent",
            "private func workoutPlanIsAlreadyScheduled(_ planID: UUID) async -> Bool",
            "await workoutPlanIsAlreadyScheduled(plan.id)",
            "scheduler.scheduledWorkouts",
            "schedulingWaiters",
            "withCheckedThrowingContinuation",
        ),
        errors,
    )
    if "func scheduleConfirmedPlan(actionID:" not in compiler:
        errors.append("WorkoutPlanSchedulingService must require a persisted confirmed action ID")

    require_text(
        "Densoso/Application/Confirmation/ConfirmationRepository.swift",
        ("var isRetryable: Bool",),
        errors,
    )
    require_text(
        "DensosoTests/ConfirmationCoordinatorTests.swift",
        ("testConfirmationErrorsDistinguishRetryableWatchReplayFromTerminalFailures",),
        errors,
    )

    confirm_repo = require_text(
        "Densoso/Infrastructure/Persistence/SwiftDataConfirmationRepository.swift",
        ("ConfirmedWorkoutPlanEntry", "ScheduleEvent", "HealthSyncOutboxEntry"),
        errors,
    )
    if "outbox" not in confirm_repo.lower():
        errors.append("workout-plan confirmation must explicitly avoid a HealthKit workout outbox write")

    require_text(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/WatchMessageOutboxTests.swift",
        (
            "testHundredOfflineMessagesRemainOrderedAndDuplicateReplaysDoNotAddRows",
            "testAcceptedAcknowledgementRemovesMessageAfterPhonePersistsItsReceipt",
            "testPendingQueueHasABoundedCapacityAndRejectsWithoutDroppingCommands",
            "testCurrentCommandsCarryExpiryAndLegacyCommandsGetAnExpiryFallback",
            "testWatchPendingActionMutationRequiresPhoneConfirmation",
        ),
        errors,
    )
    require_text(
        "DensosoTests/WatchMessageOutboxStoreTests.swift",
        (
            "testPendingCommandsAndCausalSequenceSurviveStoreRecreation",
            "testLegacyDefaultsOutboxMigratesToDurableFile",
            "testCorruptPersistedFileIsNotSilentlyReplacedByAnEmptyQueue",
            "testFileWriteFailureIsReportedToStopDispatch",
        ),
        errors,
    )
    require_text(
        "DensosoTests/WatchMessageInboxStoreTests.swift",
        (
            "testRepeatedOfflineTranscriptReplayCreatesOneDurableInboxMessage",
            "testPhoneAcknowledgesDurablePendingReceiptBeforeTranscriptProcessing",
            "testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder",
            "pendingCommands.map(\\.messageID)",
            "pendingCommands.map(\\.payload)",
            "testOutOfOrderMessagesAreReturnedInDurableArrivalOrder",
            "testConflictingPayloadWithSameMessageIDIsRejected",
            "testPendingInboxPagesMoreThan64ReceiptsInArrivalOrder",
        ),
        errors,
    )
    require_text(
        "DensosoTests/Application/AgentCoordinatorTests.swift",
        (
            "import DensosoDomain",
            "testOfflineWatchTranscriptSurvivesFailureResumesSameDraftAndConfirmsOnce",
            "hasPersistedRequestHistory(for: pending.messageID)",
        ),
        errors,
    )
    require_text(
        "Densoso/Views/ChatScreen.swift",
        (
            "displayedWatchTranscriptIDs",
            "hasPersistedRequestHistory(for: agentRequestID)",
            "guard !agentUIState.isBusy else { return }",
        ),
        errors,
    )
    require_text(
        "Densoso/Agent/AgentSession.swift",
        ("conversationHistory = try persisted.map(Self.decodePersistedMessage)",),
        errors,
    )
    require_text(
        "DensosoTests/WorkoutPlanSchedulingServiceTests.swift",
        (
            "testUnconfirmedPlanNeverCallsWorkoutScheduler",
            "testConfirmedScheduleIsIdempotentAcrossRetries",
            "testConcurrentScheduleRequestsForOneConfirmedPlanAreCoalesced",
            "testConcurrentScheduleWaitersReceiveTheSameFailure",
            "testTransientWorkoutKitFailureLeavesAUserRetryableScheduleIntent",
            "testConfirmedSinglePlanHistoryPagesAcross64EventBoundary",
            "testConfirmedMultiDayPlanKeepsPriorityForSharedActionID",
        ),
        errors,
    )
    require_text(
        "DensosoTests/WorkoutPlanCompilerTests.swift",
        (
            "testSupportedSingleGoalDraftValidatesWithoutStrengthSetData",
            "testLegacyStrengthPlanIsRejectedAndNotCompiledAsAWorkout",
            "testStrengthSetsAreRejectedEvenForAWorkoutKitSupportedActivity",
        ),
        errors,
    )

    watch_files = sorted((ROOT / "DensosoWatchExtension").glob("*.swift"))
    if not watch_files:
        errors.append("missing Watch Swift target sources")
    for path in watch_files:
        source = path.read_text(encoding="utf-8")
        if "import HealthKit" in source or "HKWorkout" in source:
            errors.append(f"Watch target contains a custom HealthKit workout path: {path.name}")
        if "OrbitPalette" in source:
            errors.append(f"Watch target must not depend on iOS-only OrbitPalette: {path.name}")
        if "AVAudioSession" in source or "AVAudioRecorder" in source or "AVCaptureAudio" in source:
            errors.append(f"Watch target contains a custom microphone capture path: {path.name}")
    for removed in (
        "DensosoWatchExtension/WatchHealthKitWorkoutManager.swift",
        "DensosoWatchExtension/DensosoWatchExtension.entitlements",
    ):
        if (ROOT / removed).exists():
            errors.append(f"obsolete Watch workout component remains: {removed}")

    require_text(
        "docs/gates/gate-08-watch.md",
        (
            "Status:",
            "100-message offline/replay fixture",
            "Legacy Watch confirmation/rejection messages are rejected by the",
            "schema-1 queued commands remain readable",
            "arrival order from receipt-filtered 64-row pages",
            "65-receipt page boundary",
            "stable 64-row pages",
            "An unconfirmed plan never calls `WorkoutScheduler`",
            "real Watch pairing",
        ),
        errors,
    )
    workflow = require_text(
        ".github/workflows/build.yml",
        ("watch:", "name: gate-08-watch", "needs: health-intelligence", "DensosoWatch", "gate-08-watch-results"),
        errors,
    )
    if "needs: health-intelligence" not in workflow:
        errors.append("Gate 8 must depend on Gate 7")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "scope": "watch-companion-and-confirmed-workoutkit-scheduling",
        "watchHealthKitWriter": False,
        "watchPendingActionMutationEnabled": False,
        "watchCommandExpiryEnforced": True,
        "watchOutboxDurableStorage": "atomic-file",
        "unconfirmedWorkoutScheduling": False,
        "hardwarePairingClaimed": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Phase 8 Watch static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
