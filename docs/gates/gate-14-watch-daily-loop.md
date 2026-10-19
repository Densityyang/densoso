# Gate 14 — Watch Daily Loop

Status: focused simulator and domain-contract gate; physical-device acceptance
remains separate.

## Scope

Checks daily snapshot summaries, pending-action confirmation boundaries,
durable quick-record envelopes, offline replay deduplication, arrival ordering,
and retry/resume behavior. Inbox reads push state, identity, sort order, and
recent-item limits into SwiftData while preserving durable arrival ordering.
The phone snapshot resolves today's DailyMetrics row with a bounded date query
and one-row fetch limit. Confirmed plan reads filter note-prefix candidates
before decoding in 64-row pages, then retain only active sessions through
tomorrow; ordinary calendar events remain isolated.
Watch outbox and phone inbox tests cover replay semantics; the phone
coordinator's activation path restores pending commands.

## Focused tests

- DensosoDomain: `DailyLoopSnapshotTests`, `TrainingPlanDraftTests`,
  `WatchMessageOutboxTests`, and `WatchWorkoutCoordinatorTests`.
- iOS tests: `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`,
  `DailyLoopSnapshotCompositionTests.testMultiDayTrainingPlanPendingActionRequiresPhoneReviewOnWatchSummary`,
  `WatchMessageInboxStoreTests.testPendingCommandReplayReturnsOnlyNonTranscriptEnvelopesInArrivalOrder`,
  `WatchMessageInboxStoreTests.testOutOfOrderMessagesAreReturnedInDurableArrivalOrder`,
  `WatchMessageInboxStoreTests.testRecentInboxQueriesFilterStatesAndApplyLimitsInArrivalOrder`,
  `TrainingPlanSchedulingServiceTests.testConfirmedPlanSchedulesOnlyWorkoutDaysAndPersistsOnePlanEntry`,
  `TrainingPlanSchedulingServiceTests.testPartialSchedulingFailureCanResumeWithoutDuplicatingCompletedWorkoutDays`,
  `WorkoutPlanSchedulingServiceTests.testConfirmedScheduleIsIdempotentAcrossRetries`,
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
