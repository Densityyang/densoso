# Gate 07 — Health Intelligence

Status: exact-commit result is recorded in the Phase 10 acceptance manifest

This gate delivers deterministic, explainable local health summaries. It does
not introduce a global health score, diagnosis, medical advice, or local/cloud
model training.

## Scope

- Sleep intervals are clipped to the local 18:00-to-18:00 health day, merged to
  avoid overlap double-counting, and separated into main sleep and naps.
  Watch-origin sleep is preferred where sources overlap. Sleep stages are
  exposed only when their coverage is at least 60 percent.
- Personal baselines use valid daily observations, median/percentiles and MAD.
  Fewer than 7 observations are learning, 7–27 are temporary, and 28 or more
  are mature. Zero MAD never creates an infinite anomaly score.
- Weight trends require at least four valid observations in each seven-day
  comparison window. Training-load maturity requires seven effort-known
  workout days in the prior 28-day window; the total is divided across four
  calendar weeks so intervening rest days count as zero. Any unknown-effort
  workout in the comparison window makes the ratio unavailable and is surfaced
  in the UI rather than treated as zero.
- Four independent domains, at most two evidence-linked recommendations,
  aggregated 7/28-day cloud context, daily/weekly briefs, and goal profiles are
  computed locally. Stable source hashes reuse report caches; changed inputs
  recompute them.
- Morning and evening reminders use the latest local `DailyLoopSnapshot`, have
  configurable local times (08:00 and 21:00 defaults), and remain opt-in. The
  weekly reminder remains available. Restoring preferences never prompts for
  notification authorization.

## Gate contract

1. Sleep overlap, cross-midnight windows, naps, multiple sources and partial
   stage coverage are deterministic.
2. Baseline readiness covers `<7`, `7–27`, and `>=28`; MAD zero, outliers and
   sparse inputs do not produce false findings.
3. Training load covers rest-day maturity, absent effort, immature history and
   every band edge.
4. Recommendations are limited to two, refer to resolvable evidence, and do
   not claim diagnoses or conflicting actions.
5. Provider context contains only aggregate 7/28-day summaries; no sample
   objects, timestamps or per-day sequence are serialized into the prompt.
6. Identical source/goal inputs reuse daily and weekly caches; changed inputs
   change the source hash and refresh the affected report.
7. Morning, evening, and weekly notifications are disabled by default;
   morning/evening times can be changed, snapshot copy contains no measured
   values, and permission is requested only after the user enables a reminder.
8. Domain tests, app tests, contract report, result bundle and logs are retained
   in `gate-07-health-intelligence-results`.

## Evidence boundary

All calculations and UI are software behavior tested with deterministic local
fixtures. The gate does not establish clinical validity, HealthKit data
completeness, signed-device background delivery, or production readiness.
PR #14 remains Draft and `blocked-by-signing`.
