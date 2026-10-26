# Gate 05 — Meal Capture

Status: approved by user after successful macOS CI

Gate 5 extends Draft PR #14 after Gate 4 approval on 2026-09-08. It implements
meal capture and confirmation only; HealthKit delivery workers remain Phase 6.

## Scope

- Camera and PhotosPicker feed transient bytes into ImageIO; camera `UIImage`
  orientations are physically normalized (including mirrored cases), images are
  resized to a 1280-pixel longest edge, encoded at JPEG 0.75 and re-created without
  source EXIF/GPS/XMP/MakerNote metadata. Raw photos are never persisted.
- Local Vision runs barcode and nutrition-label OCR first. Valid GTIN and usable
  label nutrition avoid Qwen vision.
- Barcode matches and complete local nutrition labels use a local review path.
  The sanitized image is not included in an Agent request. A package's label
  serving weight is not assumed to equal the amount eaten: the user supplies
  grams or a serving count that can be converted from a known per-serving mass;
  otherwise the local flow asks once before staging.
- Open dishes may use the independent Beijing
  `qwen3.7-flash-2026-07-15` adapter only when the feature flag, `.mealImage`
  consent and quality gate all allow it.
  Production defaults this quality gate to unavailable/closed because the
  checked-in synthetic set does not prove real-photo VLM accuracy.
- In the cumulative main PR, the default open-photo route is the explicitly
  selected DeepSeek multimodal Agent path with its separate `.mealImage`
  consent. The optional Qwen review adapter is only available when Qwen is
  explicitly selected and its own feature, quality and consent gates are open;
  it is never a fallback for a DeepSeek request.
- The pinned model receives sanitized image input and a strict JSON Schema
  response contract. Its model response must identify the pinned snapshot;
  rolling aliases are rejected. The model supports Function Calling too, but
  this meal-vision adapter does not expose or execute tool calls.
- VLM output is a closed observation schema containing labels, preparation,
  cooking/container/portion hints and occlusion only. It cannot supply food ID,
  calories or nutrient truth.
- Barcode, local nutrition-label, and open-photo candidates all pass through
  `FoodResolverV2`. V2 scoring keeps lexical, alias, preparation, mass-basis, category, history and evidence as independent axes.
  Exact barcode evidence can identify its matched package, while OCR and visual
  cues contribute only when they match a candidate.
  Candidate evidence summaries do not copy raw OCR text. Every result still requires confirmation; ambiguous
  results keep `foodID == nil` until the user selects a candidate.
- The seven V2 score axes are retained with the pending meal draft and its
  canonical receipt as audit data; this does not replace explicit confirmation.
- `PortionEstimator` implements measured, approximate, package, household and
  photo interval rules. A single photo is never measured.
- `log_meal` accepts `quantityEvidence`; exact grams are used only when the
  current user text locally verifies that amount for the matching ingredient.
  Household/count/photo estimates remain ranges, package serving mass must be
  verified by user text or local label evidence, and unknown identity or portion
  produces a single clarification instead of a calorie draft.
  An agent `photoEstimate` is accepted only when this turn contains a transient
  photo; without one, the tool asks for user-reported portion evidence instead
  of treating a model claim as visual observation.
- Broad energy ranges retain their likely point estimate with a weak evidence
  grade. The app asks at most one high-value question for each meal capture.
- V2 estimates record `meal-estimator-v2`, `portion-estimator-v2`, and
  `calorie-accounting-v3` in meal/evidence version fields for exports and review.
- `MealEstimator` propagates ingredient intervals, keeps raw/cooked distinct,
  treats oil/sugar/sauce as explicit ingredients, avoids duplicate oil for cooked
  composite entries, and preserves unknown macros as nil in the canonical range
  fields. Existing non-optional V3 point fields and `DailyMetrics` aggregates
  cannot encode unknown macros; they retain `0` compatibility placeholders and
  are not authoritative measurements. Gate 5 does not claim accurate daily macro
  totals when source macros are unknown. Modeling unknown values in those legacy
  aggregates requires a separately versioned schema migration, not an in-place
  V3 change.
- At most one high-value clarification is shown and answered before staging:
  candidate identity, missing quantity, or an unusually broad energy interval.
  Verified exact user grams remain user-reported evidence, never measured.
  Staging creates `PendingAction`; only the existing confirmation transaction
  writes Meal, receipt and nutrition outbox.

## Non-goals

- No use of the protected local OCR source directory or its validation script.
- No local general food-image model, training pipeline, GPU dependency or silent
  first-candidate selection.
- No model-written food IDs, direct database writes or automatic confirmation.
- No HealthKit outbox worker, energy semantics, Watch or full navigation redesign.
- No claim that the synthetic fixture set proves real-world photo accuracy.
- No invoice-accurate vision cost claim: usage records retain prompt/completion
  counts and model, but not cached/image-token breakdowns.

## Gate contract

The `meal-capture` job has `needs: speech` and must prove:

1. the frozen resolver fixture retains its exact-alias and raw/cooked baselines;
   focused V2 contracts verify separate alias/category, preparation/mass-basis,
   confirmed-history, barcode, local-label/visual-evidence, and ambiguity paths;
2. the frozen 100-case synthetic set reaches top-1 >=80% and top-3 >=90%;
3. the frozen 50-case synthetic portion set reaches coverage >=80% and outside <=20%;
4. package, single food, mixed/occluded/no-scale/unknown-container and correction
   paths retain honest intervals;
5. cooking oil is explicit and never duplicated for a cooked composite;
6. a selected clarification cannot be skipped, and its answer is included in the
   staged payload as user-reported evidence;
7. unknown protein/fat/carbohydrate stay nil in canonical meal/dish range fields
   and evidence through confirmation. Non-optional V3 point mirrors may contain
   `0` only as a compatibility placeholder, not as a measured zero; daily macro
   aggregates are outside this gate's accuracy claim;
8. camera right/mirrored orientations are applied before sanitizing; sanitized
   output is <=1280px, JPEG 0.75 and contains no source GPS/EXIF/XMP/MakerNote;
9. valid GTIN/OCR avoid Qwen, UPC-E is expanded with its own checksum validation,
   and open-photo use requires separate consent;
10. the pinned Qwen request/response fixture uses image Data URI and strict
    structured output, and rejects rolling model aliases and foodID/nutrient fields;
11. unconfirmed capture produces zero Meal/outbox rows, while explicit confirmation
    atomically produces one Meal, one receipt and one nutrition outbox entry.
12. barcode, nutrition-label, and visual candidate integration uses the same V2
    resolver contract; matching source evidence affects ranking independently,
    and candidate summaries and staged evidence do not persist raw barcode or
    nutrition-label OCR strings. Locally resolved barcode/label images stay out
    of model requests, and missing consumed quantity requires one local answer.

The Gate 5 XCTest result bundle retains `gate05-food-resolution.json` and
`gate05-portion-reference.json` attachments with the measured rates and the
synthetic-only source boundary.

## Evaluation boundary

`evals/gate05` is a public synthetic, deterministic dataset created without the
protected OCR source. It contains 100 expanded food-resolution cases and 50
synthetic calibration references. The latter exercise interval coverage math but
are not represented as real kitchen-scale measurements. Real photo and scale
field validation remains an evidence gap and does not remove `blocked-by-signing`.
The field benchmark status is `BLOCKED/MISSING_EVIDENCE`; passing these
synthetic checks is only evidence for the deterministic software contracts.
The current 31-row app seed has only one `raw` and one `cooked` food entry; the
remaining 29 are `unknown`. Synthetic resolver coverage therefore does not prove
production-catalog raw/cooked coverage. Open-photo Qwen remains unavailable until
both real-photo quality and catalog coverage are independently evidenced.

If any quality threshold fails, open-photo Qwen vision must remain disabled;
barcode, OCR, voice and text paths may continue.

## Historical V3 Gate 5 evidence record

This table records an earlier V3 review snapshot. It is not evidence for the
current `codex/ai-native-health-loop` branch or a PR associated with that branch.

| Evidence | Required result | Recorded result |
| --- | --- | --- |
| Historical head | Separate V3 Phase 5 implementation | `e67a444c30640da34c23becdc1f63f5f4023c5b8` |
| Historical dependencies | Gates 1–4 succeed on that head | [run 38504626897](https://github.com/Densityyang/densoso/actions/runs/38504626897) — Gates 1–5 passed |
| Resolver | alias/raw-cooked/top-1/top-3 thresholds | Passed in Gate 5 tests |
| Portion | 50-case coverage/outside thresholds | Passed in Gate 5 tests |
| Vision | orientation, GPS/EXIF/XMP/MakerNote, GTIN/UPC-E, OCR and Qwen fixture contracts | Passed in Gate 5 tests |
| Confirmation | zero pre-confirm writes; atomic Meal/receipt/outbox | Passed in Gate 5 tests |
| Privacy | no raw image or protected OCR source use | Passed in Gate 5 tests; protected local OCR files were not read |
| Artifact | `.xcresult`, logs, fixture summary and eval manifest | [gate-05-meal-capture-results, artifact 11869028384](https://github.com/Densityyang/densoso/actions/runs/38504626897/artifacts/11869028384) |
| Field benchmark | real photos and kitchen-scale samples | `BLOCKED/MISSING_EVIDENCE` |
| Historical V3 decision | Entry to Phase 6 on that separate review | Approved in the V3 review; does not describe this branch |
