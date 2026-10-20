# Gate 14 — Watch Daily Loop

Status: focused simulator and domain-contract gate; physical-device acceptance
remains separate.

## Scope

Checks daily snapshot summaries, pending-action confirmation boundaries,
durable quick-record envelopes, offline replay deduplication, arrival ordering,
and retry/resume behavior. Inbox reads push state, identity, sort order, and
recent-item limits into SwiftData while preserving durable arrival ordering;
equal ordinals use message ID as a deterministic tie-breaker across receipt
pages.
The pending-command query matches a zero UUID receipt without admitting an
envelope whose optional request ID is nil; recent receipt IDs also skip that
envelope while preserving durable inbox arrival order. Pending receipt IDs and
inbox messages are read in stable, bounded pages; Swift matches non-nil request
IDs in memory so SwiftData predicates do not force unwrap optional fields.
Repeated offline Watch refresh taps coalesce while a snapshot request remains
unacknowledged in the durable outbox. Once iPhone acknowledges it, a later tap
can enqueue a new request; transcript, confirm, and reject messages remain
independent queue entries.
Incoming Watch messages are persisted before dependency checks or execution.
New commands keep a monotonic sequence but depend only on the latest command
still awaiting a terminal receipt, so an old rejection does not poison a later
independent command. Sequenced commands wait while their predecessor is missing
or pending, and the phone replays eligible work in causal-sequence order after a
predecessor reaches processed. Rejected or conflicting predecessors terminally
reject their successors. Legacy commands and transcripts retain the durable
arrival-order barrier, including while an earlier transcript waits for iPhone
consumption. Transcripts remain pending until the user sends or otherwise
durably handles them, and are not surfaced before their dependencies are ready;
app activation and receipt-state changes resume the pending replay queue.
The Watch health snapshot derives today's health status and guidance from the
current-day brief. It queries recent terminal inbox receipts and confirmed plans;
it does not fetch DailyMetrics. Its single-session plan query starts at today,
reads note-prefix candidates in stable 64-row pages, skips terminal entries,
and stops after the next ten plans; ordinary calendar events remain isolated.
The iPhone plan editor keeps its complete confirmed-plan history query. The
Watch snapshot uses a separate 64-row paged query for the current two-day
window, skips terminal plans and rest days, and retains only the ten earliest
sessions with stable tie ordering before building summaries. Pending draft
summaries are also capped at ten, ordered by earliest expiry and action ID.
The recent receipt-ID list is capped at 100. An optional terminal causal sequence watermark covers the contiguous prefix whose receipts are all processed or rejected, allowing the Watch to discard older sequenced outbox entries even when their IDs have fallen out of that list. Missing or pending sequences stop the watermark; legacy unsequenced entries still require their individual receipt IDs.
The phone builds an in-memory sequence cache from paged inbox records on the first watermark request, then updates it as commands arrive or receipts change. App restarts rebuild the cache from durable records; no SwiftData field or migration is needed.
The Watch snapshot carries optional next-day guidance only from a brief for the
current local day. Its health payload contains domain/status pairs and a compact
recovery summary; numeric estimates, baselines, and evidence keys stay on
iPhone. Legacy numeric fields from older snapshots are ignored and are not
re-emitted. The Watch shows available nutrition, sleep, activity, and body
status labels plus the recovery status/action. It shows the guidance's
conditional note and action when present, and newer payloads remain decodable
from snapshots sent by older app versions.
The Watch compares `generatedAt` with the current day in its local calendar and
rechecks the boundary periodically. After local midnight, an older snapshot is
labeled with its most recent sync date; its health summary, recovery,
tomorrow guidance, and workout-plan schedule are hidden. Pending actions remain
available only until their individual `expiresAt` time.
The phone plan editor fetches ten single-session and ten multi-day plans per
page instead of loading the complete history up front. “Load more” appends the
next page for each plan type; a failed page read preserves loaded rows and can
be retried. An initial read failure shows a retryable error instead of an empty
history.
Watch outbox and phone inbox tests cover replay semantics; the phone
coordinator's activation path restores pending commands.
Whenever the published daily brief changes, the app rebuilds the notification
snapshot and refreshes Watch application context so manual and foreground
health refreshes reach the companion without waiting for another activation.

## Focused tests

- DensosoDomain: `DailyLoopSnapshotTests`, `TrainingPlanDraftTests`,
  `WatchMessageOutboxTests` (including
  `testCausalSequenceSurvivesAcknowledgementAndOutboxRestore`,
  `testCausalDependencyPolicyWaitsAndFailsOnRejectedOrConflictingPredecessors`,
  and `testTerminalSequenceWatermarkAcknowledgesOnlyCoveredCausalEntries`),
  and `WatchWorkoutCoordinatorTests`.
- iOS tests: `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`,
  `DailyLoopSnapshotCompositionTests.testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary`,
  `WatchMessageInboxStoreTests.testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder`,
  `WatchMessageInboxStoreTests.testCausalReplayWaitsForMissingAndPendingPredecessorThenOrdersBySequence`,
  `WatchMessageInboxStoreTests.testRejectedAndConflictingPredecessorsRejectCausalSuccessors`,
  `WatchMessageInboxStoreTests.testTerminalCausalWatermarkStopsAtMissingAndPendingSequences`,
  `WatchMessageInboxStoreTests.testTerminalCausalWatermarkCacheTracksChangesAndRebuildsAfterStoreRestart`,
  `WatchMessageInboxStoreTests.testCausalTranscriptWaitsForPredecessorAndStaysPendingUntilConsumed`,
  `WatchMessageInboxStoreTests.testLegacyPendingCommandAndTranscriptBlockNewerCommandUntilCompleted`,
  `WatchMessageInboxStoreTests.testPendingCommandQueryMatchesZeroUUIDAndSkipsNilRequestIDInArrivalOrder`,
  `WatchMessageInboxStoreTests.testPendingInboxOrdersEqualOrdinalsByMessageIDAcrossReceiptPages`,
  `WatchMessageInboxStoreTests.testOutOfOrderMessagesAreReturnedInDurableArrivalOrder`,
  `WatchMessageInboxStoreTests.testRecentInboxQueriesFilterStatesAndApplyLimitsInArrivalOrder`,
  `WatchMessageOutboxTests.testTodaySnapshotRoundTripsTomorrowGuidanceAndDecodesLegacyPayload`,
  `WatchMessageOutboxTests.testTodaySnapshotExpiresAtInjectedCalendarLocalMidnight`,
  `WatchMessageOutboxTests.testSnapshotRequestPolicyCoalescesOnlyUntilAcknowledged`,
  `TrainingPlanSchedulingServiceTests.testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry`,
  `TrainingPlanSchedulingServiceTests.testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays`,
  `TrainingPlanSchedulingServiceTests.testConfirmedPlanHistoryPagesAcrossThe64EventBoundary`,
  `TrainingPlanSchedulingServiceTests.testUpcomingTrainingSessionsAreBoundedAndOrderedAcrossPages`,
  `TrainingPlanSchedulingServiceTests.testConfirmedPlanPagesKeepAllRowsAcrossTiedTenRowBoundaries`,
  `WorkoutPlanSchedulingServiceTests.testConfirmedScheduleIsIdempotentAcrossRetries`,
  `WorkoutPlanSchedulingServiceTests.testUpcomingPlansAreBoundedOrderedAndSkipTerminalEntries`,
  `TrainingPlanScheduleQueryTests.testGetScheduleExpandsConfirmedTrainingPlanForRequestedDayIncludingRestDay`,
  `HealthProjectionActorTests.testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents`,
  `HealthProjectionActorTests.testConfirmedPlanEntriesPageHistoricalPlansAndDailySnapshotRetainsOnlyCurrentSessions`,
  `AgentCoordinatorTests.testOfflineWatchTranscriptSurvivesFailureResumesSameDraftAndConfirmsOnce`.

Confirmed multi-day training sessions expose bounded human-readable goal,
location, intensity, and reason details to schedule queries. Rest days expose
their reason only; encoded plan payloads are never returned to the Agent.

Simulator evidence does not prove Watch pairing, radio delivery, offline
reconnection, WorkoutKit presentation, or signed-device HealthKit behavior.
Those checks belong to manual Gate 15.
