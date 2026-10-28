# Gate 19 — Cloud Policy and Health Window Coverage

Status: NOT RUN — evaluated by GitHub Actions on the implementation SHA.

The gate runs focused cloud-context policy and HealthKit-window XCTest suites,
including separate Swift package tests for domain unknown/partial semantics,
then produces a structured evidence report. `testResults` records app
`xcodebuild` XCTest methods; `swiftPackageTestResults` records exact
`Suite/testMethod` Swift package filters. Source markers and test names are
reported separately from executed test results and behavioral evidence.

Required behavior includes default-deny history attachment, provider-bound
per-category consent, filtering before serialization and continuation, removal
of derived values from denied categories, explicit confirmation for permission
expansion, backup reconfirmation, a shared 42-day analysis/initial-sync window,
authorization-boundary handling, unknown-versus-absence coverage, and
idempotent rebaseline and deletion recompute.

The production HealthKit adapter does not depend on Apple's Beta
`getEarliestAuthorizedSampleDate` API. The stable path rebuilds only the bounded
42-day snapshot when that per-type boundary is unavailable; empty reads remain
unknown and stale HealthKit-derived cache rows are purged before the export gate
opens. Gate 19's software check reports the coordinator contract separately
from `liveHealthKitAuthorizationBoundary`, which remains `NOT_MEASURED` until a
signed-device authorization matrix is supplied. This device evidence is owned
by Gate 15 and is not inferred from simulator/fake-provider tests.

The report must keep uncovered or unexecuted behavior `BLOCKED` or
`NOT_MEASURED`; source-text presence cannot be promoted to runtime `PASS`. It
does not inspect provider traffic. A sanitized request artifact must be
produced and checked by the CI evidence producer before it can support a
runtime `PASS` claim.

For `provider_final_request_body`, Gate 19 exports the JSON attachment
`gate19-sanitized-provider-request-evidence.json` from the current run's
`Gate19PolicyHealthWindowTests.xcresult`. The attachment is emitted by the
scripted-transport XCTest that inspects the actual locally serialized request
bodies. It records only the provider, denied health class, capture/absence
booleans, sentinel match counts, and body byte count; it contains neither
request bodies nor sentinel values. CI checks exactly two providers against all
five denied health classes, rejects additional fields, and binds the attachment
to the same run's passing test result before the behavior check can be `PASS`.
Missing or incomplete
attachment coverage remains `BLOCKED`; a failed privacy assertion is `FAIL`.
This is evidence about local serialization before transport, not evidence about
what a live remote service received.

## Current implementation review

The implementation keeps per-provider, per-category consent default-deny,
filters aggregate summaries and health history before adding them to provider
messages, and applies a final continuation filter to recognized health tool
results. Goal fields are filtered independently: a daily deficit target requires
both nutrition and activity consent. The HealthKit window policy uses the same
inclusive 42-calendar-day lookback for analysis and initial backfill; sync
requests are clipped to each stream's authorization boundary. When that boundary
is present, historical cached values before the first fully authorized day are
removed from per-day summaries, imported workouts and HealthKit-only weight
records before the boundary are removed from direct read paths, and affected
daily projections are recomputed. Sleep uses its 18:00-to-18:00 wake-day window
when determining the first fully authorized projection day.
If boundary lookup fails, that metric's current analysis window is marked
unknown by synchronously clearing only HealthKit-derived cache/index data inside
the 42-day window before the snapshot query. Manual weights and records outside
the window are retained. A successful snapshot makes days with visible records
available; empty or failed days remain unknown, never `noData` or zero. The
foreground path purges before scheduling its async rebuild, and a generation
checked export gate blocks Agent health context until that purge succeeds. A
failed purge keeps the gate closed; an export already reading while a new
rebaseline starts is rejected after its generation changes. Daily background
refresh also forces a full-window rebaseline. Observer updates continue from
stored anchors when the per-type authorization boundary is available. On iOS
27, the adapter calls Apple's Beta `earliestAuthorizedSampleDate(for:)` API.
Earlier OS versions report `authorizationBoundaryUnavailable`; observer-triggered
sample and workout syncs then clear the bounded cache and cursor before reading
the 42-day window. The API's live limited-history behavior remains
`NOT_MEASURED` until signed-device evidence is supplied.
This does not claim immediate detection of arbitrary HealthKit permission
changes made outside the app. HealthKit workouts
are excluded from both daily-metric projection inputs and
`get_recent_workouts` unless that day's workout read state is available; manual
workouts remain eligible. Aggregate energy, step, and exercise values are
admitted to the read model only when the matching daily read state is available.

The gate starts open for a never-connected installation only when persistence has
no HealthKit cursor, sample index, HealthKit weight, or HealthKit-marked snapshot;
this keeps locally entered health context available to a user who does not use
HealthKit. A restored HealthKit-marked cache with no restored connection preference
is purged synchronously from the bounded window without querying HealthKit before
the gate opens. An unreadable cache remains closed. Each purge transaction also
deletes persisted daily and weekly derived briefs. The observable service hides
those briefs and uses a shared generation fence so a pre-purge projection cannot
commit after invalidation or republish one to the UI/Watch; a failed purge leaves
brief refresh disabled until a later purge succeeds.

The dedicated policy and sync tests include unique sentinels for all five
health classes under both DeepSeek and Qwen, a cross-domain goal-field case,
42-day inclusive-window assertions, authorization-boundary cursor cases, and a
repeated rebaseline assertion. The authorization-boundary regression also
checks an out-of-window cached weight, HealthKit-only weight row, and imported
workout, then verifies they are unavailable through the weight observation and
workout record paths. The foreground serialization fixture verifies a stale
HealthKit sentinel is present before purge and absent from the serialized
provider health summary afterward. Export-gate tests cover startup closed state,
successful purge opening, failed purge denial, and invalidation of an in-flight
export across rebaseline. A new adapter integration test passes guarded
continuation messages through both provider serializers and inspects the
captured local `URLRequest.httpBody`; a session test revokes sleep consent
during a health tool read and checks the next provider-bound continuation. An
export/restore test verifies that health consent is absent from the backup
document and a blank destination remains default-denied. A separate restore
test seeds an already-authorized destination for DeepSeek and Qwen, then checks
that restore revokes all health/history consents and advances each policy to
`needsReconfirmation` / `backupRestore` in the same transaction. Observer tests
start with stored sample and workout anchors, then verify a boundary-unavailable
callback rebuilds the bounded window and clears stale records. These tests have
not been run locally; Gate 19 remains `NOT RUN` until GitHub Actions executes
them.

The coding path now carries HealthKit read-state coverage from the application
read model into domain states. Missing or ambiguous read states produce typed
`unknown` or `partial`, while `noData` requires complete successful reads with
no observation. Legacy domain, vital, context-summary and training-load cache
payloads lacking coverage fail closed; the health-intelligence cache version
is `health-intelligence-v3`. Unknown or partial training-load summaries omit
numeric load, ratio, baseline and count placeholders from tool and narrative
JSON. Dedicated app and Swift package tests cover this local behavior, but no
GitHub execution result is available yet.

## Remaining evidence and implementation gaps

- The adapter test captures local serialized request bodies from both provider
  adapters with a scripted transport. CI retains only its sanitized result
  attachment, not the bodies or sentinel values. This evidence does not observe
  a live network service or prove what a remote service received.
- The export format does not include `ConsentRecord` or cloud-policy fields.
  The importer therefore keeps a blank destination default-denied and revokes
  authorization already present in an existing destination. CI must execute
  both restore cases before the evidence manifest can report them as `PASS`; a
  future policy-carrying backup format would need its own explicit
  `needsReconfirmation` import contract.
- Cache invalidation and explicit confirmation before expanding permission have
  no focused behavioral evidence in this gate. Keep them `NOT_MEASURED`; a
  source scan or passing XCTest suite does not establish them.
- The read-model/domain/tool coding gap for unknown-versus-absence is addressed
  with explicit typed coverage and dedicated regression tests. Until the app
  XCTest and Swift package test results are present in the CI manifest, runtime
  local semantics remain `NOT_MEASURED`; a static source-contract `PASS` is not
  a behavior result.
- Simulator fixtures cannot establish the actual earliest authorized sample
  boundary reported by iOS or whether an empty read is denied. Live HealthKit
  authorization behavior remains `NOT_MEASURED` even after local semantic
  tests pass.
- No signed-device HealthKit authorization matrix is included in this gate.
