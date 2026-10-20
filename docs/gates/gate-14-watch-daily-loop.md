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
envelope while preserving durable inbox arrival order.
The phone snapshot resolves today's DailyMetrics row with a bounded date query
and one-row fetch limit. Its single-session plan query starts at today, reads
note-prefix candidates in stable 64-row pages, skips terminal entries, and
stops after the next ten plans; ordinary calendar events remain isolated. The
multi-day scheduling service reads complete confirmed-plan history in 64-row
pages before applying its existing decode and ordering rules; the phone
snapshot filters terminal and past sessions before building summaries, then
uses plan IDs to break equal-time ties deterministically.
The phone plan editor shows a retryable read error instead of reporting an
empty history when either confirmed-plan query fails.
Watch outbox and phone inbox tests cover replay semantics; the phone
coordinator's activation path restores pending commands.

## Focused tests

- DensosoDomain: `DailyLoopSnapshotTests`, `TrainingPlanDraftTests`,
  `WatchMessageOutboxTests`, and `WatchWorkoutCoordinatorTests`.
- iOS tests: `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`,
  `DailyLoopSnapshotCompositionTests.testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary`,
  `WatchMessageInboxStoreTests.testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder`,
  `WatchMessageInboxStoreTests.testPendingCommandQueryMatchesZeroUUIDAndSkipsNilRequestIDInArrivalOrder`,
  `WatchMessageInboxStoreTests.testPendingInboxOrdersEqualOrdinalsByMessageIDAcrossReceiptPages`,
  `WatchMessageInboxStoreTests.testOutOfOrderMessagesAreReturnedInDurableArrivalOrder`,
  `WatchMessageInboxStoreTests.testRecentInboxQueriesFilterStatesAndApplyLimitsInArrivalOrder`,
  `TrainingPlanSchedulingServiceTests.testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry`,
  `TrainingPlanSchedulingServiceTests.testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays`,
  `TrainingPlanSchedulingServiceTests.testConfirmedPlanHistoryPagesAcrossThe64EventBoundary`,
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
