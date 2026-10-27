# Gate 18 — Meal Estimate Usefulness and Deterministic Accounting

Gate status: NOT RUN — evaluate this implementation SHA in GitHub Actions.

`fieldCalibration`: `NOT_MEASURED` and non-blocking for the deterministic
engineering gate. No real labeled meal set, measurement protocol, or held-out
field measurements are included. Synthetic fixtures cannot establish
real-world food-resolution accuracy or calorie error. Keep this metric status
separate from the Gate 18 software-contract status in the CI report.

The frozen food-resolution fixture reports Top-1/Top-3 separately in Gate 5;
those fixture measurements do not establish field calibration.

The deterministic meal-domain suite and focused iOS integration tests should
verify these contracts:

- A photo with multiple independent dishes preserves them as separate dishes;
  a composite dish preserves its distinct, supported ingredients without
  counting one ingredient twice.
- Photo-estimated grams remain an uncertainty range with
  `photoWithoutScale` provenance. They must never be promoted to exact or
  measured grams without a current, locally validated user report or scale.
- Food resolution, mass basis, portion ranges, nutrient density, cooking-oil
  priors, and ingredient/dish/meal kcal totals use the deterministic local
  estimator. Identical fixture inputs and algorithm versions produce the same
  likely kcal result, and oil is included at most once per dish.
- Estimates retain finite `low <= likely <= high`, confidence, provenance, and
  algorithm-version evidence. The primary confirmation summary shows likely
  kcal and confidence; the potentially broad interval remains in collapsed
  details instead of dominating the default presentation.
- A consumed fraction is applied only when the current user turn explicitly
  states one and its scope is unambiguous. The pending draft scales ingredient
  grams, dish portions, and all nutrient ranges together, carries typed
  current-user provenance, and the confirmed record stores the same consumed
  totals and provenance. A multi-dish fraction without whole-meal scope, a
  fraction scoped to only one dish, or an approximate/negated fraction is not
  applied; the tool asks one clarification before staging. If the user cannot
  resolve that scope, no full-meal intake draft is staged.
- Ordinary high-impact estimate uncertainty may request at most one
  clarification; if the user still cannot resolve that estimate, retain a
  reasonable low-confidence likely estimate unless food identity or portion
  evidence is unavailable. Unresolved consumed-fraction scope is different:
  do not stage a full-meal intake draft.

The gate must not claim field-calibrated Top-1/Top-3 accuracy or calorie error
from synthetic fixtures. The existing real-world targets remain Top-1 at least
80%, Top-3 at least 90%, median absolute percentage calorie error at most 25%,
and P90 at most 50%. Until supported by labeled field evidence, report field
calibration as `NOT_MEASURED`; do not convert that metric status into a Gate
failure or an accuracy `PASS`.
