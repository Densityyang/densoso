# Gate 13 — Energy Accounting

Status: focused CI gate over existing energy accounting and meal estimate tests.

## Scope

Checks component-wise observed basal/active expenditure, explicit-profile
fallback for only missing components, historical effective profile/weight
selection, unavailable cases, shared metric availability and coverage,
likely-range meal estimates, and projection fingerprint stability. Workout
estimates must not be added again when observed active energy is available.

## Focused tests

- DensosoDomain: `EnergyAccountingTests`, `DailyMetricsUsabilityTests`.
- iOS tests: `CaloricEnergySemanticsTests.testMeasuredActiveEnergyIsNotAddedToWorkoutEnergy`,
  `CaloricEnergySemanticsTests.testWorkoutPresenceDoesNotChangeEstimatedActiveEnergyFallback`,
  `CaloricEnergySemanticsTests.testMissingEffectiveProfileDoesNotInventEnergyExpenditure`,
  `CalorieEstimatorTests.testExplicitOilIsAddedOnceWithoutCookingMultiplier`, and
  `CalorieEstimatorTests.testInferredOilProducesAnHonestInterval`.

Only deterministic fixtures run here. No health estimate from this gate should
be interpreted as a diagnosis or as a real-world energy-balance guarantee.
