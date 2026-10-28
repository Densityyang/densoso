# Gate 15 — Real Device Acceptance

Status: NOT RUN — manual evidence required.

This gate requires an authorized tester with a signed iPhone and paired Apple
Watch. A Simulator run, automated screenshot, or CI workflow cannot mark Gate
15 as passed.

Record one row for every required device scenario. Gate 16 accepts `Status: PASS`
only when every row identifies the tester, device model, OS, app build, the
full commit SHA of the source that was installed on the devices, a
timezone-qualified timestamp, an HTTPS evidence URL, and the SHA-256 digest of
the original evidence (for example, obtain it with
`shasum -a 256 <evidence-file>`). This is the **Tested Source SHA**, not the
later workflow commit SHA that records this evidence.

Use this commit sequence so the evidence can be checked without a self-referential
SHA:

1. Finish and commit the app/source under test as commit **A**. Install that
   build on the signed iPhone and paired Watch, and record A's full SHA in every
   row as `Tested Source SHA`.
2. After device testing is complete, update this evidence document and commit
   it as **B**. Between A and B, this document must be the only changed path.
   Do not include app, source, project, workflow, or other documentation edits
   in B or any intermediate commit.
3. Run the release workflow at B. Its `GITHUB_SHA` is the
   `currentWorkflowSHA`; the report records both this value and the rows'
   `testedSourceSHA`.

The Gate 16 aggregator verifies that A is an available commit and an ancestor
of B, then compares `git diff A B`. It permits only
`docs/gates/gate-15-real-device-acceptance.md` to differ. Any other changed path,
a non-ancestor SHA, or unavailable history blocks Gate 15. The gate-status job
therefore needs full Git history (`fetch-depth: 0`); a shallow checkout blocks
verification. Reviewers must open each evidence item and verify its digest
before recording the manual result; the aggregator validates format and commit
binding but does not download private evidence artifacts.

| Device | Tester | Model | OS version | App build | Tested Source SHA | Scenario ID | Result | Timestamp | Evidence URL | Evidence SHA-256 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| iPhone | @pending | pending | pending | pending | pending | iphone-healthkit | pending | pending | pending | pending |
| iPhone | @pending | pending | pending | pending | pending | iphone-speech-analyzer | pending | pending | pending | pending |
| iPhone | @pending | pending | pending | pending | pending | iphone-camera-photo | pending | pending | pending | pending |
| iPhone | @pending | pending | pending | pending | pending | iphone-background | pending | pending | pending | pending |
| iPhone | @pending | pending | pending | pending | pending | iphone-notifications | pending | pending | pending | pending |
| Apple Watch | @pending | pending | pending | pending | pending | watch-snapshot | pending | pending | pending | pending |
| Apple Watch | @pending | pending | pending | pending | pending | watch-quick-record | pending | pending | pending | pending |
| Apple Watch | @pending | pending | pending | pending | pending | watch-offline-queue-replay | pending | pending | pending | pending |
| Apple Watch | @pending | pending | pending | pending | pending | watch-reconnect | pending | pending | pending | pending |
| Apple Watch | @pending | pending | pending | pending | pending | watch-single-target-upgrade-outbox | pending | pending | pending | pending |
| Apple Watch | @pending | pending | pending | pending | pending | watch-workoutkit | pending | pending | pending | pending |

The tester must attach the device matrix and original test evidence. Do not
replace missing device evidence with simulator output.

For `watch-single-target-upgrade-outbox`, install the tested build over the
previous dual-target Watch build without deleting the app. Queue a durable Watch
transcript while the iPhone is unreachable before upgrading, then verify after
upgrade and reconnection that the transcript remains pending and is accepted by
the iPhone exactly once. A clean install does not satisfy this migration row.
