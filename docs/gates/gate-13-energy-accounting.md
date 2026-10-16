# Gate 13 — Energy Accounting

Status: focused CI gate over existing energy accounting and meal estimate tests.

## Scope

Checks observed basal-plus-active expenditure, explicit-profile fallback,
historical effective profile/weight selection, unavailable cases, likely-range
meal estimates, and projection fingerprint stability. Workout estimates must
not be added again when observed active energy is available.

## Focused tests

- DensosoDomain: `EnergyAccountingTests`.
- iOS tests: `CaloricEnergySemanticsTests.testMeasuredActiveEnergyIsNotAddedToWorkoutEnergy`,
  `CaloricEnergySemanticsTests.testWorkoutPresenceDoesNotChangeEstimatedActiveEnergyFallback`,
  `CaloricEnergySemanticsTests.testMissingEffectiveProfileDoesNotInventEnergyExpenditure`,
  `CalorieEstimatorTests.testExplicitOilIsAddedOnceWithoutCookingMultiplier`, and
  `CalorieEstimatorTests.testInferredOilProducesAnHonestInterval`.

Only deterministic fixtures run here. No health estimate from this gate should
be interpreted as a diagnosis or as a real-world energy-balance guarantee.
