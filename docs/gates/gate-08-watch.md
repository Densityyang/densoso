# Gate 08 — Watch Companion and WorkoutKit

Status: exact-commit result is recorded in the Phase 10 acceptance manifest

The Watch target is a companion for the phone app, not an independent health
database, microphone recorder, or workout tracker.

## Scope

- WatchConnectivity sends bounded, versioned message envelopes. The Watch
  stores outgoing messages durably and retries with `sendMessage` when
  reachable or `transferUserInfo` when offline; the phone persists inbox
  messages and receipts transactionally and treats message IDs idempotently.
  The phone's `accepted` acknowledgement means its durable inbox owns the
  envelope, even if transcript review/action confirmation remains pending.
  On app startup, pending non-transcript commands are replayed in durable
  arrival order from receipt-filtered 64-row pages; transcripts remain in the
  review queue rather than being silently submitted. Terminal action failures
  close the command receipt; transient persistence/commit failures leave it
  pending for recovery.
- The phone reads complete single-workout plan history in stable 64-row pages;
  action scheduling scans bounded pages and preserves multi-day-plan priority.
- The Watch shows a small current-day snapshot, accepts system text dictation,
  and can confirm or reject an existing phone-side draft. A transcript creates
  a draft on the phone and does not itself write a health record.
- Workout plans use a single supported activity and one open, time or distance
  goal. Legacy strength-set payloads remain decodable only for compatibility
  and are rejected by the active compiler.
- WorkoutKit scheduling follows the persisted explicit phone confirmation.
  Interrupted scheduling is retryable and duplicate scheduling is guarded by
  the stable plan ID.
- The plan editor is reachable under Trends/Activity; there is no separate
  bottom tab for plans.

## Gate contract

1. iPhone and Watch schemes compile on the macOS runner.
2. A 100-message offline/replay fixture preserves order and accepts each
   message ID once; conflicting payloads are rejected.
   Pending inbox reads also preserve transcript and command order across a
   65-receipt page boundary.
3. Offline transcript recovery yields the same durable phone-side draft.
4. Replayed confirmation is idempotent and a workout plan never enters the
   HealthKit workout outbox.
5. An unconfirmed plan never calls `WorkoutScheduler`; unsupported activity or
   goal returns a readable local error.
6. Watch source files do not import HealthKit or declare custom microphone or
   HealthKit entitlements.
7. Domain/app result bundles, build/test logs and contract report are retained
   in `gate-08-watch-results`.

## Evidence boundary

Simulator/fake transport tests do not establish real Watch pairing, offline
radio behavior, WorkoutKit availability on signed hardware, or TestFlight
acceptance. The signing gate remains blocked.
