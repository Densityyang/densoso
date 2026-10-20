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
The phone snapshot resolves today's DailyMetrics row with a bounded date query
and one-row fetch limit. Its single-session plan query starts at today, reads
note-prefix candidates in stable 64-row pages, skips terminal entries, and
stops after the next ten plans; ordinary calendar events remain isolated. The
iPhone plan editor keeps its complete confirmed-plan history query. The Watch
snapshot uses a separate 64-row paged query for the current two-day window,
skips terminal plans and rest days, and retains only the ten earliest sessions
with stable tie ordering before building summaries. Pending draft summaries are
also capped at ten, ordered by earliest expiry and action ID.
The Watch snapshot carries optional next-day guidance only from a brief for the
current local day. Its domain payload contains only domain/status pairs, so
numeric estimates, baselines, and evidence keys stay on iPhone; the Watch shows
available nutrition, sleep, activity, and body status labels plus the recovery
status/action. It shows the guidance's conditional note and action when present,
and newer payloads remain decodable from snapshots sent by older app versions.
The phone plan editor fetches ten single-session and ten multi-day plans per
page instead of loading the complete history up front. “Load more” appends the
next page for each plan type; a failed page read preserves loaded rows and can
be retried. An initial read failure shows a retryable error instead of an empty
history.
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
  `WatchMessageOutboxTests.testTodaySnapshotRoundTripsTomorrowGuidanceAndDecodesLegacyPayload`,
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
