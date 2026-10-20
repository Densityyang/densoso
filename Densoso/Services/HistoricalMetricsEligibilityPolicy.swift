import DensosoDomain
import Foundation

/// Shared eligibility rule for historical expenditure recalculation paths.
/// Observed energy does not substitute for a valid historical profile and weight.
enum HistoricalMetricsEligibilityPolicy {
    static func hasValidInputs(
        profile: EffectiveProfile?,
        weight: EffectiveWeight?,
        on day: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let profile,
              profile.dateOfBirth.timeIntervalSince1970.isFinite,
              let age = profile.age(in: calendar), age >= 0,
              let weight,
              weight.measuredAt <= day,
              weight.kilograms.isFinite, weight.kilograms > 0 else { return false }
        return true
    }
}
