import Foundation
import CryptoKit
import DensosoDomain

/// 热量计算引擎 —— 全部纯函数，无副作用
enum CaloricEngine {

    // MARK: - 运动消耗估算

    /// MET 值查表
    static func met(for workoutType: String) -> Double {
        switch workoutType {
        case "running":  return 8.0
        case "walking":  return 4.3
        case "cycling":  return 6.0
        case "swimming": return 6.0
        case "strength": return 5.0
        case "hiit":     return 10.0
        case "yoga":     return 2.5
        default:         return 4.0
        }
    }

    /// 运动消耗 = MET × 体重(kg) × 时长(h)
    static func workoutCalories(type: String, durationMinutes: Int, weightKg: Double) -> Int {
        let hours = Double(durationMinutes) / 60.0
        return Int(round(met(for: type) * weightKg * hours))
    }

    // MARK: - 缺口

    /// 当日热量缺口（正数=减脂，负=盈余）
    static func dailyDeficit(totalExpenditure: Int, totalIntake: Int) -> Int {
        totalExpenditure - totalIntake
    }

    // MARK: - 周汇总

    struct WeeklySummary {
        let totalDeficitKcal: Int
        let avgDailyDeficitKcal: Double
        let projectedWeightLossKg: Double
        let bestDay: DailyMetrics?
        let worstDay: DailyMetrics?
        let totalMeals: Int
        let totalWorkouts: Int
        let daysWithData: Int
    }

    static func weeklySummary(dailyMetrics: [DailyMetrics]) -> WeeklySummary {
        let usableMetrics = dailyMetrics.filter {
            $0.energyQuality != "unavailable" && !$0.requiresRecompute
        }
        let totalDeficit = usableMetrics.map(\.deficitKcal).reduce(0, +)
        let days = max(usableMetrics.count, 1)
        let avgDaily = Double(totalDeficit) / Double(days)
        let projectedLoss = Double(totalDeficit) / 7700.0
        let best = usableMetrics.max(by: { $0.deficitKcal < $1.deficitKcal })
        let worst = usableMetrics.min(by: { $0.deficitKcal < $1.deficitKcal })
        let totalMeals = dailyMetrics.map(\.mealCount).reduce(0, +)
        let totalWorkouts = dailyMetrics.map(\.workoutCount).reduce(0, +)

        return WeeklySummary(
            totalDeficitKcal: totalDeficit,
            avgDailyDeficitKcal: avgDaily,
            projectedWeightLossKg: projectedLoss,
            bestDay: best,
            worstDay: worst,
            totalMeals: totalMeals,
            totalWorkouts: totalWorkouts,
            daysWithData: usableMetrics.count
        )
    }

    // MARK: - 目标预测

    /// 按当前日均缺口预估达到目标体重所需天数
    /// - Returns: nil 表示无法预测（目标不低于当前体重，或缺口为负）
    static func projectDaysToTarget(
        currentWeightKg: Double,
        targetWeightKg: Double,
        avgDailyDeficit: Double
    ) -> Int? {
        let deltaKg = targetWeightKg - currentWeightKg
        guard deltaKg < 0 else { return nil }
        guard avgDailyDeficit > 0 else { return nil }
        let totalDeficitNeeded = abs(deltaKg) * 7700.0
        return Int(ceil(totalDeficitNeeded / avgDailyDeficit))
    }

    // MARK: - 每日结算

    /// 根据某天的所有餐和运动，计算 DailyMetrics
    static func computeDailyMetrics(
        date: Date,
        meals: [MealRecord],
        workouts: [WorkoutRecord],
        effectiveProfile: EffectiveProfile?,
        effectiveWeight: EffectiveWeight?,
        healthKitActiveEnergyKcal: Double? = nil,
        healthKitRestingEnergyKcal: Double? = nil,
        healthKitSteps: Double? = nil,
        healthKitExerciseMinutes: Double? = nil,
        fingerprintContext: DailyMetricsProjectionFingerprintContext = .init()
    ) -> DailyMetrics {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        let dayMeals = meals.filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }
        let dayWorkouts = workouts.filter { calendar.isDate($0.date, inSameDayAs: startOfDay) }

        let intakeRanges = dayMeals.compactMap { meal in
            try? EstimateRange(
                low: meal.energyLowKcal,
                likely: meal.energyLikelyKcal,
                high: meal.energyHighKcal
            )
        }
        let totalIntake = Double(dayMeals.map(\.totalCaloriesKcal).reduce(0, +))
        let intake = (try? EstimateRange.sum(intakeRanges))
            ?? (try! EstimateRange.point(max(totalIntake, 0)))
        // V3 DailyMetrics macros are compatibility aggregates. A meal's zero
        // mirror can mean unknown; use the optional meal ranges for evidence.
        let totalProtein = dayMeals.map(\.proteinG).reduce(0, +)
        let totalFat = dayMeals.map(\.fatG).reduce(0, +)
        let totalCarbs = dayMeals.map(\.carbsG).reduce(0, +)

        let expenditure = EnergyAccounting.expenditure(
            observedBasalEnergyKcal: healthKitRestingEnergyKcal,
            observedActiveEnergyKcal: healthKitActiveEnergyKcal,
            profile: effectiveProfile,
            effectiveWeightKg: effectiveWeight?.kilograms
        )
        let estimatedBasal: Double? = {
            guard let profile = effectiveProfile,
                  let age = profile.age,
                  let weightKg = effectiveWeight?.kilograms
            else {
                return nil
            }
            return EnergyAccounting.basalMetabolicRate(
                sex: profile.biologicalSex,
                weightKg: weightKg,
                heightCm: profile.heightCm,
                age: age
            )
        }()
        let basal = validEnergy(healthKitRestingEnergyKcal) ?? estimatedBasal
        let active = validEnergy(healthKitActiveEnergyKcal)
            ?? expenditure.map { max($0.likely - (basal ?? 0), 0) }
        let energyQuality: String
        switch expenditure?.source {
        case .some(.observed): energyQuality = "observed"
        case .some(.estimated): energyQuality = "estimated"
        case .none: energyQuality = "unavailable"
        }

        let balanceLow = expenditure.map { $0.low - intake.high } ?? 0
        let balanceLikely = expenditure.map { $0.likely - intake.likely } ?? 0
        let balanceHigh = expenditure.map { $0.high - intake.low } ?? 0
        let coverageJSON = makeCoverageJSON(
            intakePresent: !dayMeals.isEmpty,
            profileAvailable: effectiveProfile != nil,
            weightAvailable: effectiveWeight != nil,
            basalObserved: validEnergy(healthKitRestingEnergyKcal) != nil,
            activeObserved: validEnergy(healthKitActiveEnergyKcal) != nil,
            stepsObserved: validEnergy(healthKitSteps) != nil,
            exerciseObserved: validEnergy(healthKitExerciseMinutes) != nil
        )
        let fingerprint = projectionFingerprint(
            day: startOfDay,
            meals: dayMeals,
            workouts: dayWorkouts,
            profile: effectiveProfile,
            weight: effectiveWeight,
            activeEnergy: healthKitActiveEnergyKcal,
            basalEnergy: healthKitRestingEnergyKcal,
            steps: healthKitSteps,
            exerciseMinutes: healthKitExerciseMinutes,
            context: fingerprintContext
        )

        return DailyMetrics(
            date: startOfDay,
            bmrKcal: roundedInteger(basal ?? 0),
            activeCaloriesKcal: roundedInteger(active ?? 0),
            totalExpenditureKcal: roundedInteger(expenditure?.likely ?? 0),
            totalIntakeKcal: roundedInteger(intake.likely),
            deficitKcal: roundedInteger(balanceLikely),
            proteinG: totalProtein,
            fatG: totalFat,
            carbsG: totalCarbs,
            mealCount: dayMeals.count,
            workoutCount: dayWorkouts.count,
            intakeEnergyLowKcal: intake.low,
            intakeEnergyLikelyKcal: intake.likely,
            intakeEnergyHighKcal: intake.high,
            expenditureEnergyLowKcal: expenditure?.low ?? 0,
            expenditureEnergyLikelyKcal: expenditure?.likely ?? 0,
            expenditureEnergyHighKcal: expenditure?.high ?? 0,
            energyBalanceLowKcal: balanceLow,
            energyBalanceLikelyKcal: balanceLikely,
            energyBalanceHighKcal: balanceHigh,
            activeEnergyKcal: validEnergy(healthKitActiveEnergyKcal),
            basalEnergyKcal: validEnergy(healthKitRestingEnergyKcal),
            steps: validEnergy(healthKitSteps),
            exerciseMinutes: validEnergy(healthKitExerciseMinutes),
            weightKg: effectiveWeight?.kilograms,
            energyQuality: energyQuality,
            dataCoverageJSON: coverageJSON,
            projectionVersion: fingerprintContext.algorithmVersion,
            sourceFingerprint: fingerprint,
            requiresRecompute: false
        )
    }

    static func projectionFingerprint(
        day: Date,
        meals: [MealRecord],
        workouts: [WorkoutRecord],
        profile: EffectiveProfile?,
        weight: EffectiveWeight?,
        activeEnergy: Double? = nil,
        basalEnergy: Double? = nil,
        steps: Double? = nil,
        exerciseMinutes: Double? = nil,
        context: DailyMetricsProjectionFingerprintContext = .init()
    ) -> String {
        sourceFingerprint(
            day: day,
            meals: meals,
            workouts: workouts,
            profile: profile,
            weight: weight,
            activeEnergy: activeEnergy,
            basalEnergy: basalEnergy,
            steps: steps,
            exerciseMinutes: exerciseMinutes,
            context: context
        )
    }

    private static func validEnergy(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    private static func roundedInteger(_ value: Double) -> Int {
        guard value.isFinite, value < Double(Int.max), value > Double(Int.min) else { return 0 }
        return Int(value.rounded())
    }

    private static func makeCoverageJSON(
        intakePresent: Bool,
        profileAvailable: Bool,
        weightAvailable: Bool,
        basalObserved: Bool,
        activeObserved: Bool,
        stepsObserved: Bool,
        exerciseObserved: Bool
    ) -> String {
        let values = [
            "intake": intakePresent,
            "profile": profileAvailable,
            "weight": weightAvailable,
            "basalEnergy": basalObserved,
            "activeEnergy": activeObserved,
            "steps": stepsObserved,
            "exerciseMinutes": exerciseObserved,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return value
    }

    private static func sourceFingerprint(
        day: Date,
        meals: [MealRecord],
        workouts: [WorkoutRecord],
        profile: EffectiveProfile?,
        weight: EffectiveWeight?,
        activeEnergy: Double?,
        basalEnergy: Double?,
        steps: Double?,
        exerciseMinutes: Double?,
        context: DailyMetricsProjectionFingerprintContext
    ) -> String {
        let mealKeys = meals.map {
            "meal:\($0.id.uuidString.lowercased()):calories:\($0.totalCaloriesKcal):energy:\($0.energyLowKcal):\($0.energyLikelyKcal):\($0.energyHighKcal):protein:\($0.proteinG):fat:\($0.fatG):carbs:\($0.carbsG)"
        }.sorted()
        let workoutKeys = workouts.map {
            "workout:\($0.id.uuidString.lowercased()):date:\($0.date.timeIntervalSince1970):type:\($0.type):duration:\($0.durationMinutes):estimated:\($0.estimatedCaloriesBurned):intensity:\($0.intensity):origin:\($0.workoutOrigin):energy-source:\($0.energySource ?? "none")"
        }.sorted()
        let material = ([
            "day:\(day.timeIntervalSince1970)",
            "profile:\(profile?.sourceRevisionID.uuidString.lowercased() ?? "none")",
            "profile-date:\(profile?.dateOfBirth.timeIntervalSince1970 ?? -1)",
            "profile-sex:\(profile?.biologicalSex.rawValue ?? "none")",
            "profile-height:\(profile?.heightCm ?? -1)",
            "profile-activity:\(profile?.activityLevel.rawValue ?? "none")",
            "weight:\(weight?.measuredAt.timeIntervalSince1970 ?? -1):\(weight?.kilograms ?? -1):\(weight?.source.rawValue ?? "none")",
            "active:\(activeEnergy ?? -1)",
            "basal:\(basalEnergy ?? -1)",
            "steps:\(steps ?? -1)",
            "exercise:\(exerciseMinutes ?? -1)",
        ] + mealKeys + workoutKeys + context.canonicalComponents).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
