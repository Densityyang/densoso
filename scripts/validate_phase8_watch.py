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
            "public enum WatchPayload",
            "public struct WatchMessageOutbox",
            "case messageIDCollision(UUID)",
            "maximumTranscriptLength = 4_000",
        ),
        errors,
    )
    inbox = require_text(
        "Densoso/Infrastructure/WatchConnectivity/WatchMessageInboxStore.swift",
        (
            "func ingest(_ envelope:", "payloadHash", "WatchMessageReceiptRecord", "context.transaction {",
            "func recentReceivedMessageIDs(limit: Int = 100)",
            "func pendingCommandEnvelopes() throws -> [WatchMessageEnvelope]",
        ),
        errors,
    )
    phone = require_text(
        "Densoso/Infrastructure/WatchConnectivity/PhoneWatchConnectivityCoordinator.swift",
        (
            "session.updateApplicationContext", "didReceiveUserInfo", "didReceiveMessage",
            "pendingTranscriptRevision", "recentReceivedMessageIDs()",
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

    compiler = require_text(
        "Densoso/Services/WorkoutPlanCompiler.swift",
        (
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
        ),
        errors,
    )
    require_text(
        "DensosoTests/WatchMessageInboxStoreTests.swift",
        (
            "testRepeatedOfflineTranscriptReplayCreatesOneDurableInboxMessage",
            "testPhoneAcknowledgesDurablePendingReceiptBeforeTranscriptProcessing",
            "testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder",
            "testOutOfOrderMessagesAreReturnedInDurableArrivalOrder",
            "testConflictingPayloadWithSameMessageIDIsRejected",
        ),
        errors,
    )
    require_text(
        "DensosoTests/Application/AgentCoordinatorTests.swift",
        (
            "testOfflineWatchTranscriptSurvivesFailureResumesSameDraftAndConfirmsOnce",
            "hasPersistedRequestHistory(for: pending.messageID)",
        ),
        errors,
    )
    require_text(
        "Densoso/Views/ChatScreen.swift",
        ("displayedWatchTranscriptIDs", "hasPersistedRequestHistory(for: agentRequestID)", "guard !isProcessing else { return }"),
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
        "unconfirmedWorkoutScheduling": False,
        "hardwarePairingClaimed": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Phase 8 Watch static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
