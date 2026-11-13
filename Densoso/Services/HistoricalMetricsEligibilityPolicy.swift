import DensosoDomain
import Foundation

/// Shared eligibility rule for historical expenditure recalculation paths.
/// Observed energy does not substitute for a valid historical profile and weight.
enum HistoricalMetricsEligibilityPolicy {
    static func referenceDate(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day == today { return now }
        guard day < today,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
            return day
        }
        return nextDay.addingTimeInterval(-0.000_001)
    }

    static func hasValidInputs(
        profile: EffectiveProfile?,
        weight: EffectiveWeight?,
        asOf referenceDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let profile,
              profile.dateOfBirth.timeIntervalSince1970.isFinite,
              profile.sourceEffectiveFrom <= referenceDate,
              profile.effectiveAt <= referenceDate,
              let age = profile.age(in: calendar), age >= 0,
              profile.heightCm.isFinite, profile.heightCm > 0,
              profile.biologicalSex == .male || profile.biologicalSex == .female,
              profile.activityLevel != .unspecified,
              let weight,
              weight.measuredAt <= referenceDate,
              weight.kilograms.isFinite, weight.kilograms > 0 else { return false }
        return true
    }

    static func markPendingIfHistoricalInputsAreMissing(
        _ metrics: DailyMetrics,
        on date: Date,
        now: Date,
        profile: EffectiveProfile?,
        weight: EffectiveWeight?,
        calendar: Calendar = .current
    ) {
        let day = calendar.startOfDay(for: date)
        guard day < calendar.startOfDay(for: now),
              !hasValidInputs(
                  profile: profile,
                  weight: weight,
                  asOf: referenceDate(for: day, now: now, calendar: calendar),
                  calendar: calendar
              ) else { return }

        // The stored scalar fields are compatibility mirrors. The quality and
        // pending flag prevent them from entering any energy aggregation.
        metrics.bmrKcal = 0
        metrics.activeCaloriesKcal = 0
        metrics.totalExpenditureKcal = 0
        metrics.deficitKcal = 0
        metrics.expenditureEnergyLowKcal = 0
        metrics.expenditureEnergyLikelyKcal = 0
        metrics.expenditureEnergyHighKcal = 0
        metrics.energyBalanceLowKcal = 0
        metrics.energyBalanceLikelyKcal = 0
        metrics.energyBalanceHighKcal = 0
        metrics.energyQuality = "unavailable"
        metrics.requiresRecompute = true
    }
}
